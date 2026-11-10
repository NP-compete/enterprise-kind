#!/usr/bin/env bash
# Static checks that need no cluster, so CI can gate a chart bump.
#
# The failure mode being caught: bumping a pinned chart whose values keys
# were renamed. That renders fine on the old version and fails eighteen
# minutes into a cold build on the new one.
#
#   make lint              everything
#   make lint ONLY=charts  one section (charts|manifests|shell|versions)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ONLY="${ONLY:-all}"
FAILED=0
section() { [[ "${ONLY}" == "all" || "${ONLY}" == "$1" ]]; }
fail() { printf '%s %s\n' "$(_c '1;31' 'FAIL')" "$*" >&2; FAILED=1; }

LINT_DIR="${BUILD_DIR}/lint"

# Each run `rm -rf`s this directory, so two at once corrupt each other and
# report missing-file failures that have nothing to do with the manifests.
LINT_LOCK="${BUILD_DIR}/.lint.lock"
if ! mkdir "${LINT_LOCK}" 2>/dev/null; then
  if [[ -f "${LINT_LOCK}/pid" ]] && kill -0 "$(cat "${LINT_LOCK}/pid")" 2>/dev/null; then
    die "another lint is running (pid $(cat "${LINT_LOCK}/pid")); wait for it or kill it"
  fi
  warn "removing a stale lint lock"
  rm -rf "${LINT_LOCK}"; mkdir "${LINT_LOCK}"
fi
echo $$ > "${LINT_LOCK}/pid"
trap 'rm -rf "${LINT_LOCK}"' EXIT INT TERM

rm -rf "${LINT_DIR}"; mkdir -p "${LINT_DIR}/values" "${LINT_DIR}/manifests"

# Placeholder values for everything platform-install.sh substitutes at install
# time. They only have to be syntactically plausible -- nothing is deployed.
export BASE_DOMAIN URL_SUFFIX CLUSTER_NAME REGISTRY_NAME REGISTRY_HOST_PORT \
       NODE_IMAGE_ETCD PG_INSTANCES
export GRAFANA_ADMIN_PASSWORD="lint" KEYCLOAK_ADMIN_PASSWORD="lint" \
       KEYCLOAK_ADMIN_USERNAME="lint" KEYCLOAK_DB_PASSWORD="lint" \
       SSO_ADMIN_USERNAME="lint" SSO_ADMIN_PASSWORD="lint" \
       SSO_VIEWER_USERNAME="lint" SSO_VIEWER_PASSWORD="lint" \
       OIDC_SECRET_GRAFANA="lint" OIDC_SECRET_ARGOCD="lint" \
       OIDC_SECRET_HEADLAMP="lint" OIDC_SECRET_OAUTH2PROXY="lint" \
       OAUTH2_PROXY_COOKIE_SECRET="lint" REALM_CHECKSUM="lint" \
       PORTAL_CONFIG_CHECKSUM="lint" REGISTRY_CONTAINER_IP="10.89.1.2" \
       S3_CONFIG_CHECKSUM="lint" S3_ACCESS_KEY="lint" S3_SECRET_KEY="lint" \
       GRAFANA_DB_PASSWORD="lint"
# The PEM blocks are indented literals spliced into YAML; a single line keeps
# the indentation valid without carrying a real certificate into CI.
export PLATFORM_CA_PEM_INDENTED="        # lint placeholder"
export PLATFORM_CA_PEM_INDENTED6="      # lint placeholder"
export COSIGN_PUBLIC_KEY_INDENTED="                      # lint placeholder"

V="${ROOT_DIR}/platform/values"
M="${ROOT_DIR}/platform/manifests"

render_all() {
  local f
  # The same whitelist the installer uses. A bare `envsubst` here would also
  # expand the charts' own $__file{...} placeholders into YAML flow mappings
  # and report failures that would never happen on a real install.
  for f in "${V}"/*.yaml; do envsubst "${PLATFORM_SUBST}" < "${f}" > "${LINT_DIR}/values/$(basename "${f}")"; done
  for f in "${M}"/*.yaml; do envsubst "${PLATFORM_SUBST}" < "${f}" > "${LINT_DIR}/manifests/$(basename "${f}")"; done
}

# release|namespace|repo/chart|version-variable|values-file
# Pipe-delimited, not colon: OCI refs (oci://...) contain colons.
CHARTS=(
  "cert-manager|cert-manager|jetstack/cert-manager|CHART_CERT_MANAGER|cert-manager.yaml"
  "ingress-nginx|ingress-nginx|ingress-nginx/ingress-nginx|CHART_INGRESS_NGINX|ingress-nginx.yaml"
  "metrics-server|kube-system|metrics-server/metrics-server|CHART_METRICS_SERVER|metrics-server.yaml"
  "cnpg|cnpg-system|cnpg/cloudnative-pg|CHART_CNPG|cnpg.yaml"
  "keycloak|identity|codecentric/keycloakx|CHART_KEYCLOAK|keycloak.yaml"
  "oauth2-proxy|identity|oauth2-proxy/oauth2-proxy|CHART_OAUTH2_PROXY|oauth2-proxy.yaml"
  "vault|vault|hashicorp/vault|CHART_VAULT|vault.yaml"
  "external-secrets|external-secrets|external-secrets/external-secrets|CHART_EXTERNAL_SECRETS|external-secrets.yaml"
  "kps|observability|prometheus-community/kube-prometheus-stack|CHART_KUBE_PROM_STACK|kube-prometheus-stack.yaml"
  "loki|observability|grafana/loki|CHART_LOKI|loki.yaml"
  "alloy|observability|grafana/alloy|CHART_ALLOY|alloy.yaml"
  "velero|velero|vmware-tanzu/velero|CHART_VELERO|velero.yaml"
  "kyverno|kyverno|kyverno/kyverno|CHART_KYVERNO|kyverno.yaml"
  "argocd|argocd|argo/argo-cd|CHART_ARGOCD|argo-cd.yaml"
  "headlamp|headlamp|headlamp/headlamp|CHART_HEADLAMP|headlamp.yaml"
  "openshell|openshell|oci://ghcr.io/nvidia/openshell/helm-chart|CHART_OPENSHELL|openshell.yaml"
)

add_repos() {
  log "refreshing helm repos"
  while read -r name url; do
    [[ -z "${name}" ]] && continue
    helm repo add "${name}" "${url}" >/dev/null 2>&1 || true
  done <<'REPOS'
ingress-nginx https://kubernetes.github.io/ingress-nginx
jetstack https://charts.jetstack.io
prometheus-community https://prometheus-community.github.io/helm-charts
grafana https://grafana.github.io/helm-charts
argo https://argoproj.github.io/argo-helm
headlamp https://kubernetes-sigs.github.io/headlamp/
metrics-server https://kubernetes-sigs.github.io/metrics-server/
kyverno https://kyverno.github.io/kyverno/
codecentric https://codecentric.github.io/helm-charts
oauth2-proxy https://oauth2-proxy.github.io/manifests
hashicorp https://helm.releases.hashicorp.com
external-secrets https://charts.external-secrets.io
vmware-tanzu https://vmware-tanzu.github.io/helm-charts
metallb https://metallb.github.io/metallb
aqua https://aquasecurity.github.io/helm-charts
kedacore https://kedacore.github.io/charts
cnpg https://cloudnative-pg.github.io/charts
REPOS
  helm repo update >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- versions
# Every pin must still exist upstream. A chart version yanked from the index
# turns `make all` into a cold-build failure with no local change to explain
# it; better to learn that from CI.
if section versions; then
  need helm
  add_repos
  log "checking that every pinned chart version still exists"
  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r _ _ chart var _ <<<"${entry}"
    ver="${!var}"
    if helm show chart "${chart}" --version "${ver}" >/dev/null 2>&1; then
      ok "${chart} ${ver}"
    else
      fail "${chart} ${ver} (${var}) is not available in the index"
    fi
  done
fi

# ---------------------------------------------------------------- charts
# The real gate. Rendering with the pinned version is what catches a values
# key the chart renamed or dropped between releases.
if section charts; then
  need helm
  [[ "${ONLY}" == "charts" ]] && add_repos
  render_all
  log "rendering every chart against its pinned version"
  CHARTS_RENDERED=1
  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r rel ns chart var vals <<<"${entry}"
    ver="${!var}"
    args=(template "${rel}" "${chart}" --version "${ver}" --namespace "${ns}")
    [[ -n "${vals}" ]] && args+=(-f "${LINT_DIR}/values/${vals}")
    # Declare the CRD-backed API groups the real cluster has, so charts that
    # gate on capabilities render what they actually will. OpenShell's
    # preflight hard-fails without the Agent Sandbox group.
    args+=(--kube-version 1.37.0
           --api-versions agents.x-k8s.io/v1beta1
           --api-versions agents.x-k8s.io/v1alpha1
           --api-versions monitoring.coreos.com/v1)
    if out="$(helm "${args[@]}" 2>&1 >"${LINT_DIR}/${rel}.rendered.yaml")"; then
      ok "${rel} (${chart} ${ver})"
    else
      fail "${rel} (${chart} ${ver}) did not render"
      printf '%s\n' "${out}" | sed 's/^/      /' >&2
    fi
  done
fi

# ---------------------------------------------------------------- manifests
if section manifests; then
  render_all
  log "validating raw manifests"
  if command -v kubeconform >/dev/null 2>&1; then
    # CRD-backed kinds (Kyverno policies, the CNPG Cluster, MetalLB pools)
    # are not in the stock schema set; the community catalogue has them.
    if kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.37.0 \
         -schema-location default \
         -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
         "${LINT_DIR}/manifests/"*.yaml; then
      ok "manifests validate"
    else
      fail "kubeconform rejected one or more manifests"
    fi
  elif python3 -c 'import yaml' 2>/dev/null; then
    warn "kubeconform not installed -- parsing YAML only, not validating schemas"
    for f in "${LINT_DIR}/manifests/"*.yaml; do
      python3 -I -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "${f}" \
        || fail "not valid YAML: $(basename "${f}")"
    done
    ok "manifests parse"
  else
    # Neither tool present. Say so rather than failing: a missing linter is
    # not a broken manifest, and reporting it as one trains people to ignore
    # this output. CI installs kubeconform, so the real gate still runs.
    warn "neither kubeconform nor python3-yaml available -- manifest check skipped"
    warn "  install with: brew install kubeconform"
  fi
fi

# ---------------------------------------------------------------- collisions
# A hand-written manifest and a chart that produce the same namespace/name
# do not error at render time -- they collide at apply time, and `kubectl
# apply` merges rather than replaces. For PodDisruptionBudgets that merge
# produces an object with both minAvailable and maxUnavailable set, which the
# API server rejects outright and which stops a cold install dead.
#
# This needs BOTH sides rendered, so it only runs on a full pass. Guarding on
# "charts were actually rendered this run" rather than on the section name:
# an ONLY=manifests run leaves no *.rendered.yaml behind, the comparison sees
# zero chart objects, and a vacuous "no collisions" is worse than no check.
if [[ "${CHARTS_RENDERED:-0}" == "1" ]]; then
  log "checking for manifest/chart object collisions"
  # One extractor for both sides, splitting on `---` so a `name:` from the
  # previous document cannot leak into the next one. An earlier version of
  # this used a different expression per side and invented collisions.
  coll="$(
    { for f in "${LINT_DIR}"/*.rendered.yaml "${LINT_DIR}/manifests/"*.yaml; do
        [[ -e "${f}" ]] || continue
        awk -v RS='(^|\n)---[ \t]*\n' '
          {
            k=""; n=""; ns="";
            split($0, L, "\n");
            for (i in L) {
              if (L[i] ~ /^kind: /         && k  == "") { sub(/^kind: /,        "", L[i]); k  = L[i] }
              if (L[i] ~ /^  name: /       && n  == "") { sub(/^  name: /,      "", L[i]); n  = L[i] }
              if (L[i] ~ /^  namespace: /  && ns == "") { sub(/^  namespace: /, "", L[i]); ns = L[i] }
            }
            if (k && n && ns) print k"/"ns"/"n
          }' "${f}"
      done
    } | sed 's/[ \t"]*$//' | sort | uniq -d
  )"
  n_chart="$(grep -hc '^kind: ' "${LINT_DIR}"/*.rendered.yaml 2>/dev/null | paste -sd+ - | bc)"
  if [[ "${n_chart:-0}" -lt 100 ]]; then
    fail "collision check saw only ${n_chart:-0} chart objects -- refusing to report a pass"
  elif [[ -z "${coll}" ]]; then
    ok "no object is defined by both a chart and a manifest (${n_chart} chart objects checked)"
  else
    fail "the same object is defined twice (chart and manifest):"
    printf '%s\n' "${coll}" | sed 's/^/      /' >&2
  fi
else
  warn "collision check skipped -- needs a full run (charts + manifests)"
fi

# ---------------------------------------------------------- gitops manifests
# Everything under apps/ is read straight from git by Argo CD, which does
# not run envsubst. A ${VAR} that survives into a manifest becomes a literal
# -- "podinfo.${BASE_DOMAIN}" as a hostname, which the API server rejects.
if section manifests || [[ "${ONLY}" == "all" ]]; then
  log "checking apps/ for envsubst placeholders Argo CD cannot expand"
  stray="$(grep -rn '\${[A-Z_]\+}' "${ROOT_DIR}"/apps --include='*.yaml' 2>/dev/null \
           | grep -v 'upstream\.yaml' | grep -vE ':\s*#' || true)"
  if [[ -z "${stray}" ]]; then
    ok "no unexpandable placeholders under apps/"
  else
    fail "apps/ contains envsubst placeholders; Argo CD will apply them literally:"
    printf '%s\n' "${stray}" | sed 's/^/      /' >&2
  fi
fi

# ---------------------------------------------------------------- shell
if section shell; then
  log "shellcheck"
  if command -v shellcheck >/dev/null 2>&1; then
    # Gate at warning and above: the info/style tier is almost entirely
    # "prefer ${x//a/b} over sed" on code that is clear as written, and a
    # check that fails on taste gets ignored rather than fixed.
    #   SC1091 lib.sh is sourced by path; shellcheck cannot follow it here.
    #   SC2155 `local x="$(cmd)"` masking an exit status -- every use here is
    #          a basename/dirname that cannot meaningfully fail.
    if shellcheck -x -S warning -e SC1091,SC2155 "${ROOT_DIR}"/scripts/*.sh; then
      ok "shell scripts clean"
    else
      fail "shellcheck reported problems"
    fi
  else
    warn "shellcheck not installed -- skipping"
  fi
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
  ok "lint passed"
else
  die "lint failed"
fi
