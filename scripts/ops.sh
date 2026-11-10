#!/usr/bin/env bash
# Day-to-day operator commands. Read-only unless stated.
#
# Usage: ops.sh <doctor|urls|secrets|status|token|seal|break-glass|demo|gitops|push|sign|openshell|agent-stack|agent-creds> [args]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_urls() {
S="${ROOT_DIR}/.secrets"
r() { [[ -s "${S}/$1" ]] && cat "${S}/$1" || echo '(run make install)'; }

apw="$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -z "${apw}" ]] && apw="(disabled or rotated)"

cat <<EOF

  ┌─ single sign-on ───────────────────────────────────────────────────────┐
   Sign in to every console below with one Keycloak account:

     ${SSO_ADMIN_USERNAME} / ${SSO_ADMIN_PASSWORD}   (group: platform-admins)
     ${SSO_VIEWER_USERNAME} / ${SSO_VIEWER_PASSWORD}   (group: platform-viewers)

   Keycloak    https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}      realm: platform
     admin console:  ${KEYCLOAK_ADMIN_USERNAME} / ${KEYCLOAK_ADMIN_PASSWORD}
  └────────────────────────────────────────────────────────────────────────┘

  ┌─ consoles ─────────────────────────────────────────────────────────────┐
   Headlamp    https://headlamp.${BASE_DOMAIN}${URL_SUFFIX}
                 "Sign in with OIDC", or a token from: make token
   Argo CD     https://argocd.${BASE_DOMAIN}${URL_SUFFIX}
                 "LOG IN VIA KEYCLOAK", or break-glass admin / ${apw}
   Grafana     https://grafana.${BASE_DOMAIN}${URL_SUFFIX}
                 "Sign in with Keycloak", or break-glass admin / $(r grafana-admin-password)
   Prometheus  https://prometheus.${BASE_DOMAIN}${URL_SUFFIX}      (SSO via oauth2-proxy)
   Alertmanager https://alertmanager.${BASE_DOMAIN}${URL_SUFFIX}   (SSO via oauth2-proxy)
  └────────────────────────────────────────────────────────────────────────┘

   Registry    https://registry.${BASE_DOMAIN}${URL_SUFFIX}   (TLS + auth)
     browsing the UI prompts for the registry login:
       $(r registry-username) / $(r registry-password)
     push with:  make push IMG=myapp:1.0
     endpoint:   localhost:${REGISTRY_HOST_PORT}  (in-cluster: ${REGISTRY_NAME}:5000)
   Context    ${KUBECONTEXT}

   Certificates are signed by the cluster's private CA. Run 'make trust-ca'
   once to silence browser warnings, or accept the warning per host.

EOF
}

cmd_status() {
cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist"

echo; log "nodes"
kc get nodes -L topology.kubernetes.io/zone,ingress-ready

echo; log "helm releases"
helm list -A --kube-context "${KUBECONTEXT}" -o table | sed 's/\t/  /g'

echo; log "pods that are not Running/Completed"
bad=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' || true)
if [[ -z "${bad}" ]]; then ok "every pod is healthy"; else echo "${bad}"; fi

echo; log "warnings in the last 2 minutes (live problems only)"
# Kubernetes keeps events for an hour, so a UI full of red is usually history.
# This window is what actually matters right now.
kc get events -A --field-selector type=Warning -o json 2>/dev/null | python3 -I -c "
import sys, json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
seen = {}
for e in json.load(sys.stdin)['items']:
    ts = e.get('lastTimestamp') or e.get('eventTime')
    if not ts:
        continue
    age = (now - datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))).total_seconds()
    if age < 120:
        seen[(e['reason'], e['involvedObject'].get('name', ''))] = int(age)
for (reason, name), age in sorted(seen.items(), key=lambda kv: kv[1]):
    print(f'  {age:4}s ago  {reason}  {name}')
if not seen:
    print('  none -- anything red in a UI is older than this and already resolved')
" 2>/dev/null || warn "could not read events"

echo; log "ingresses"
kc get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[*].host,TLS:.spec.tls[*].secretName'

echo; log "certificates"
kc get certificate -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status' 2>/dev/null || true

echo; log "prometheus targets down"
down=$(kc get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/targets?state=active' 2>/dev/null \
  | jq -r '.data.activeTargets[] | select(.health!="up") | "  \(.scrapePool)  \(.lastError)"' 2>/dev/null | sort -u)
if [[ -z "${down}" ]]; then ok "every scrape target is up"; else echo "${down}"; fi

echo; log "kyverno policy violations"
kc get policyreport -A --no-headers 2>/dev/null \
  | awk '{f+=$4} END {if (f>0) print "  " f " failing rules -- kubectl get policyreport -A"; else print "  none"}' \
  || warn "kyverno reports unavailable"
echo
}

cmd_token() {
# Mints a login token for the Headlamp console.
#   scripts/ops.sh token          -> cluster-admin, 8h
#   scripts/ops.sh token viewer   -> read-only, 8h

role="${1:-admin}"
case "${role}" in
  admin)  sa=headlamp-login-admin ;;
  viewer) sa=headlamp-login-viewer ;;
  *) die "usage: token.sh [admin|viewer]" ;;
esac

tok="$(kc -n headlamp create token "${sa}" --duration=8h)"
printf '%s\n' "${tok}"
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "${tok}" | pbcopy
  warn "copied to clipboard (${sa}, valid 8h)"
fi
}

cmd_seal() {
# Encrypt a Secret so it is safe to commit to git.
#
#   kubectl create secret generic my-secret --from-literal=k=v \
#     --dry-run=client -o yaml | make seal > my-sealed-secret.yaml
#
# Only this cluster's sealed-secrets controller can decrypt the result. Its
# private key lives in kube-system/sealed-secrets-key* and is covered by the
# Velero daily schedule -- lose it and sealed secrets are unrecoverable.

KUBESEAL="$(command -v kubeseal || true)"
if [[ -z "${KUBESEAL}" ]]; then
  # Vendor it rather than requiring a system install, so `make seal` just works.
  KUBESEAL="${BUILD_DIR}/bin/kubeseal"
  if [[ ! -x "${KUBESEAL}" ]]; then
    mkdir -p "${BUILD_DIR}/bin"
    case "$(uname -m)" in
      arm64|aarch64) arch=arm64 ;;
      *)             arch=amd64 ;;
    esac
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    log "fetching kubeseal ${SEALED_SECRETS_VERSION} (${os}-${arch})"
    curl -sL --fail \
      "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${SEALED_SECRETS_VERSION#v}-${os}-${arch}.tar.gz" \
      -o "${BUILD_DIR}/kubeseal.tgz" || die "could not download kubeseal"
    tar -xzf "${BUILD_DIR}/kubeseal.tgz" -C "${BUILD_DIR}/bin" kubeseal || die "could not extract kubeseal"
    chmod +x "${KUBESEAL}"
  fi
fi

exec "${KUBESEAL}" --context "${KUBECONTEXT}" \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --format yaml
}

cmd_break_glass() {
# Emergency access when Keycloak itself is down or misconfigured.
#
#   break-glass.sh on    -- re-enable the local login forms on Grafana and Argo CD
#   break-glass.sh off   -- back to Keycloak-only (same as `make install`)
#
# This deliberately edits the live cluster rather than the values files, so the
# next `make install` restores the SSO-only posture on its own.

case "${1:-on}" in
  on)
    warn "re-enabling local logins -- this bypasses Keycloak"
    kc -n observability patch secret kps-grafana --type merge \
      -p "{\"stringData\":{\"admin-password\":\"$(cat "${ROOT_DIR}/.secrets/grafana-admin-password")\"}}" >/dev/null
    kc -n observability get cm kps-grafana -o json \
      | sed 's/disable_login_form = true/disable_login_form = false/; s/oauth_auto_login = true/oauth_auto_login = false/' \
      | kc apply -f - >/dev/null
    kc -n observability rollout restart deployment/kps-grafana >/dev/null
    kc -n argocd patch configmap argocd-cm --type merge -p '{"data":{"admin.enable":"true"}}' >/dev/null
    kc -n argocd rollout restart deployment/argocd-server >/dev/null
    ok "local logins enabled"
    echo
    echo "  Grafana  admin / $(cat "${ROOT_DIR}/.secrets/grafana-admin-password")"
    echo "  Argo CD  admin / $(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo '(secret deleted -- argocd admin initial-password reset)')"
    echo "  Headlamp use a ServiceAccount token: make token"
    echo
    warn "run 'make install' (or break-glass.sh off) to return to Keycloak-only"
    ;;
  off)
    "${ROOT_DIR}/scripts/platform-install.sh"
    ;;
  *) die "usage: break-glass.sh [on|off]" ;;
esac
}

cmd_demo() {
# Deploys / removes the reference workload in the `apps` tenant namespace.

SUBST='${BASE_DOMAIN}'
rendered="${BUILD_DIR}/podinfo.yaml"
envsubst "${SUBST}" < "${ROOT_DIR}/apps/podinfo/deployment.yaml" > "${rendered}"

case "${1:-apply}" in
  apply)
    kc apply -f "${ROOT_DIR}/platform/manifests/tenant-namespace.yaml" >/dev/null
    kc apply -f "${rendered}"
    wait_rollout apps deployment/podinfo
    suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"
    ok "podinfo up at https://podinfo.${BASE_DOMAIN}${suffix}"
    ;;
  delete)
    kc delete -f "${rendered}" --ignore-not-found
    ok "podinfo removed"
    ;;
  load)
    # Generate traffic so the dashboards and traces have something to show.
    suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"
    log "sending traffic to podinfo for 60s"
    end=$(( $(date +%s) + 60 ))
    while [[ $(date +%s) -lt ${end} ]]; do
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/" || true
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/delay/1" || true
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/status/500" || true
    done
    ok "traffic generated"
    ;;
  *) die "usage: demo.sh [apply|delete|load]" ;;
esac
}

cmd_gitops() {
# Hands this repository to Argo CD.
#   make gitops-bootstrap REPO=https://github.com/you/kind-platform.git
# Optional: PATH_=gitops  REV=main  (private repos: GIT_USERNAME / GIT_TOKEN)

GITOPS_REPO="${REPO:-${GITOPS_REPO:-}}"
GITOPS_PATH="${PATH_:-${GITOPS_PATH:-gitops}}"
GITOPS_REVISION="${REV:-${GITOPS_REVISION:-HEAD}}"
[[ -n "${GITOPS_REPO}" ]] || die "set REPO=<git url>, e.g. make gitops-bootstrap REPO=https://github.com/you/repo.git"
export GITOPS_REPO GITOPS_PATH GITOPS_REVISION

if [[ -n "${GIT_TOKEN:-}" ]]; then
  log "registering repository credentials"
  kc -n argocd create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="${GITOPS_REPO}" \
    --from-literal=username="${GIT_USERNAME:-git}" \
    --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f - >/dev/null
  ok "credentials stored in argocd/gitops-repo"
fi

envsubst '${GITOPS_REPO} ${GITOPS_PATH} ${GITOPS_REVISION}' \
  < "${ROOT_DIR}/gitops/root-app.yaml" > "${BUILD_DIR}/root-app.yaml"
kc apply -f "${BUILD_DIR}/root-app.yaml"
ok "Argo CD now reconciles ${GITOPS_REPO}:${GITOPS_REVISION}/${GITOPS_PATH}/apps"
ok "child Applications under gitops/apps/ carry a literal repoURL"
}

cmd_push() {
# Push a local image into the cluster registry.
#
#   make push IMG=myapp:1.0
#
# The registry is TLS-protected and requires auth, so this logs in first using
# the generated credentials in .secrets/.

IMG="${1:?usage: push.sh <image:tag>}"
USER_FILE="${ROOT_DIR}/.secrets/registry-username"
PASS_FILE="${ROOT_DIR}/.secrets/registry-password"
[[ -s "${PASS_FILE}" ]] || die "no registry credentials -- run scripts/cluster.sh pki"

REF="localhost:${REGISTRY_HOST_PORT}/${IMG}"
log "logging in to localhost:${REGISTRY_HOST_PORT}"
"${CE}" login --cert-dir "${ROOT_DIR}/.secrets" \
  -u "$(cat "${USER_FILE}")" -p "$(cat "${PASS_FILE}")" \
  "localhost:${REGISTRY_HOST_PORT}" >/dev/null 2>&1 \
  || "${CE}" login --tls-verify=false \
       -u "$(cat "${USER_FILE}")" -p "$(cat "${PASS_FILE}")" \
       "localhost:${REGISTRY_HOST_PORT}" >/dev/null \
  || die "registry login failed"

"${CE}" tag "${IMG}" "${REF}"
"${CE}" push --tls-verify=false "${REF}" >/dev/null || die "push failed"
ok "pushed ${REF}"
echo
echo "  In a pod:   image: ${REGISTRY_NAME}:5000/${IMG}"
echo "              (not localhost:${REGISTRY_HOST_PORT}/... -- Kyverno verifies the in-cluster name)"
echo "  Needs:      imagePullSecrets: [{name: registry-creds}]"
echo "  The 'apps' namespace already has it on its default ServiceAccount."
}

cmd_sign() {
# Sign an image in the local registry so Kyverno will admit it.
#
#   make push IMG=myapp:1.0      # push it
#   make sign IMG=myapp:1.0      # sign it
#
# Key-based signing with no transparency log: there is no Rekor instance here,
# and reaching the public one would make local builds depend on the internet.
# The trade-off is no independent audit trail of what was signed when.

IMG="${1:?usage: sign-image.sh <image:tag>}"
REF="localhost:${REGISTRY_HOST_PORT}/${IMG}"
COSIGN_BIN="${BUILD_DIR}/bin/cosign"
KEY="${ROOT_DIR}/.secrets/cosign.key"

if [[ ! -x "${COSIGN_BIN}" ]]; then
  mkdir -p "${BUILD_DIR}/bin"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  log "fetching cosign ${COSIGN_VERSION}"
  # v2: supports offline key-based signing directly. v3 requires a signing
  # config to disable the transparency log, which buys nothing locally.
  curl -sL --fail "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-${os}-${arch}" \
    -o "${COSIGN_BIN}" || die "could not download cosign"
  chmod +x "${COSIGN_BIN}"
fi

if [[ ! -s "${KEY}" ]]; then
  log "generating a cosign signing key"
  COSIGN_PASSWORD="" "${COSIGN_BIN}" generate-key-pair \
    --output-key-prefix "${ROOT_DIR}/.secrets/cosign" >/dev/null 2>&1 \
    || die "could not generate a cosign key pair"
  chmod 600 "${KEY}"
  warn "new signing key -- re-run 'make install' so Kyverno picks up the public key"
fi

COSIGN_PASSWORD="" "${COSIGN_BIN}" sign --yes --key "${KEY}" \
  --tlog-upload=false --allow-insecure-registry \
  --registry-username "$(cat "${ROOT_DIR}/.secrets/registry-username")" \
  --registry-password "$(cat "${ROOT_DIR}/.secrets/registry-password")" \
  "${REF}" >/dev/null 2>&1 || die "signing failed"

COSIGN_PASSWORD="" "${COSIGN_BIN}" verify --key "${ROOT_DIR}/.secrets/cosign.pub" \
  --insecure-ignore-tlog=true --allow-insecure-registry \
  --registry-username "$(cat "${ROOT_DIR}/.secrets/registry-username")" \
  --registry-password "$(cat "${ROOT_DIR}/.secrets/registry-password")" \
  "${REF}" >/dev/null 2>&1 || die "signed, but verification failed"

ok "signed and verified: ${REF}"
}

cmd_doctor() {
  # Checks the things that actually broke during development, in dependency
  # order, and stops at the first that would make later checks meaningless.
  # Every failure prints the command that fixes it.
  local issues=0
  _bad()  { printf '  %s %s\n' "$(_c '1;31' '✗')" "$1" >&2; shift; local l
            for l in "$@"; do printf '      %s\n' "${l}" >&2; done; issues=$((issues+1)); }
  _good() { printf '  %s %s\n' "$(_c '1;32' '✓')" "$1" >&2; }

  echo; log "diagnosing ${CLUSTER_NAME}"

  # --- host prerequisites --------------------------------------------------
  local missing=()
  for t in kind kubectl helm jq openssl envsubst "${CONTAINER_ENGINE}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    _bad "missing tools: ${missing[*]}" "brew install ${missing[*]}"
  else _good "required tools present"; fi

  if ! "${CONTAINER_ENGINE}" info >/dev/null 2>&1; then
    _bad "${CONTAINER_ENGINE} is not responding" \
         "podman machine start"
    echo; die "${issues} problem(s); nothing else can be checked"
  fi
  _good "${CONTAINER_ENGINE} is running"

  # --- cluster -------------------------------------------------------------
  if ! cluster_exists; then
    _bad "cluster '${CLUSTER_NAME}' does not exist" "make up && make install"
    echo; die "${issues} problem(s) found"
  fi
  _good "cluster '${CLUSTER_NAME}' exists"

  if ! kc get --raw /readyz >/dev/null 2>&1; then
    _bad "the API server is not answering" \
         "podman start ${CLUSTER_NAME}-control-plane" \
         "if that fails: make clean && make all"
    echo; die "${issues} problem(s) found"
  fi
  _good "API server reachable"

  local notready
  notready="$(kc get nodes --no-headers 2>/dev/null | grep -cv ' Ready ' || true)"
  [[ "${notready}" == "0" ]] \
    && _good "all nodes Ready" \
    || _bad "${notready} node(s) not Ready" "kubectl get nodes" "kubectl describe node <name>"

  # --- secrets / cluster mismatch -----------------------------------------
  # .secrets/ outlives `make clean`, so a rebuilt cluster can inherit
  # credentials belonging to a Vault that no longer exists.
  if [[ -s "${ROOT_DIR}/.secrets/vault-installer-secret-id" ]] \
     && kc -n vault get pod vault-0 >/dev/null 2>&1; then
    if kc -n vault exec vault-0 -- vault status 2>/dev/null | grep -q 'Sealed  *false'; then
      if ! kc -n vault exec vault-0 -- vault write -field=token auth/approle/login \
           role_id="$(cat "${ROOT_DIR}/.secrets/vault-installer-role-id" 2>/dev/null)" \
           secret_id="$(cat "${ROOT_DIR}/.secrets/vault-installer-secret-id")" \
           >/dev/null 2>&1; then
        _bad "Vault credentials in .secrets/ belong to a previous cluster" \
             "make reset   # wipes .secrets/ and rebuilds from nothing"
      else _good "Vault credentials match this cluster"; fi
    fi
  fi

  # --- sealed Vault --------------------------------------------------------
  if kc -n vault get pod vault-0 >/dev/null 2>&1; then
    if kc -n vault exec vault-0 -- vault status 2>/dev/null | grep -q 'Sealed  *true'; then
      _bad "Vault is sealed (normal after any restart)" "./scripts/identity.sh vault"
    else _good "Vault unsealed"; fi
  fi

  # --- workloads -----------------------------------------------------------
  local bad
  bad="$(kc get pods -A --no-headers 2>/dev/null | grep -vc 'Running\|Completed' || true)"
  if [[ "${bad}" != "0" ]]; then
    _bad "${bad} pod(s) not Running" \
         "kubectl get pods -A | grep -v Running" \
         "re-run 'make install' -- it is idempotent and resumes"
  else _good "all pods Running"; fi

  local pending
  pending="$(kc get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${pending}" != "0" ]]; then
    _bad "${pending} pod(s) Pending" \
         "kubectl get events -A --field-selector reason=FailedScheduling" \
         "usually a ResourceQuota or leftover anti-affinity from an old ReplicaSet"
  fi

  # --- unsatisfiable PDBs, which silently block every drain ----------------
  local badpdb
  badpdb="$(kc get pdb -A -o json 2>/dev/null \
            | jq '[.items[] | select(.status.currentHealthy < .status.desiredHealthy)] | length' 2>/dev/null || echo 0)"
  [[ "${badpdb}" == "0" ]] \
    && _good "all PodDisruptionBudgets satisfiable" \
    || _bad "${badpdb} PodDisruptionBudget(s) cannot be satisfied" \
            "kubectl get pdb -A" \
            "at one replica a budget must be maxUnavailable, never minAvailable"

  # --- host wiring ---------------------------------------------------------
  if grep -q "home.${BASE_DOMAIN}" /etc/hosts 2>/dev/null; then
    _good "/etc/hosts maps *.${BASE_DOMAIN}"
  else
    _bad "*.${BASE_DOMAIN} is not in /etc/hosts -- consoles will not resolve" "make hosts"
  fi

  # Compare FINGERPRINTS, not names. Matching on common name reports
  # "trusted" when the keychain holds a CA from a previous cluster -- which
  # is exactly what happens after `make reset`, and presents in the browser
  # as ERR_CERT_AUTHORITY_INVALID with no way to click through under HSTS.
  if [[ -s "${ROOT_DIR}/.secrets/platform-root-ca.crt" ]]; then
    local want have
    want="$(openssl x509 -in "${ROOT_DIR}/.secrets/platform-root-ca.crt" -noout -fingerprint -sha256 2>/dev/null \
            | cut -d= -f2 | tr -d ': ')"
    have="$(security find-certificate -a -Z 2>/dev/null | grep -c "${want}" || true)"
    if [[ "${have:-0}" -gt 0 ]]; then
      _good "platform CA trusted by macOS"
    elif security find-certificate -c "kind-platform-root-ca" >/dev/null 2>&1; then
      _bad "a DIFFERENT platform CA is trusted -- this cluster's CA is not" \
           "the keychain holds a CA from a previous cluster (.secrets/ was wiped)" \
           "make untrust-ca && make trust-ca"
    else
      _bad "platform CA is not in the keychain -- browsers will warn" "make trust-ca"
    fi
  fi

  # --- ingress -------------------------------------------------------------
  if curl -sk --max-time 10 -o /dev/null "https://home.${BASE_DOMAIN}${URL_SUFFIX}/" 2>/dev/null; then
    _good "https://home.${BASE_DOMAIN}${URL_SUFFIX} responds"
  else
    _bad "the portal is not answering" \
         "kubectl -n ingress-nginx get pods" \
         "make hosts   # if the name does not resolve"
  fi

  echo
  if [[ ${issues} -eq 0 ]]; then
    ok "no problems found -- try 'make urls' or 'make smoke'"
  else
    die "${issues} problem(s) found; fixes are listed above"
  fi
}

cmd_openshell() {
  # Sets up local access to the OpenShell gateway: pulls the client mTLS
  # bundle the chart generated, registers the gateway with the CLI if it is
  # installed, and port-forwards.
  #
  # Port-forward rather than ingress on purpose: the gateway requires client
  # certificates, and an ingress proxy cannot present one on your behalf.
  # Exposing it properly means enableMtls=false plus OIDC against Keycloak.
  local ns=openshell
  local dir="${HOME}/.config/openshell/gateways/k8s/mtls"
  kc -n "${ns}" get statefulset openshell >/dev/null 2>&1 \
    || die "openshell is not installed -- run: make install"

  log "fetching the client TLS bundle"
  mkdir -p "${dir}"
  local k
  for k in ca.crt tls.crt tls.key; do
    kc -n "${ns}" get secret openshell-client-tls -o "jsonpath={.data.${k//./\\.}}" \
      | base64 -d > "${dir}/${k}" \
      || die "could not read ${k} from secret openshell-client-tls"
  done
  chmod 600 "${dir}"/tls.key
  ok "client bundle in ${dir}"

  if command -v openshell >/dev/null 2>&1; then
    openshell gateway add https://127.0.0.1:8080 --local --name k8s >/dev/null 2>&1 \
      && ok "gateway 'k8s' registered with the openshell CLI" \
      || warn "could not register the gateway; add it manually once the port-forward is up"
  else
    warn "the 'openshell' CLI is not installed; the port-forward below still works"
  fi

  log "port-forwarding https://127.0.0.1:8080 (ctrl-c to stop)"
  kc -n "${ns}" port-forward svc/openshell 8080:8080
}

cmd_agent_stack() {
  # Builds and deploys the Red Hat template-agent + template-ui stack into
  # this cluster. Upstream ships `make kind`, which creates its OWN cluster;
  # this targets the existing one and adapts the overlay to platform policy.
  #
  #   agent-stack build    build and load the images only
  #   agent-stack deploy   apply the overlay (images must already be loaded)
  #   agent-stack          both
  local sub="${1:-all}"
  local SRC="${BUILD_DIR}/template-src"
  local AGENT_SHA=75072aeb0825553dd04af7c21a2e21d063797ae9
  local UI_SHA=7a037b5fec170573c77a81db48a3c81a57d6c2d0
  local NS=template-agent

  _clone() { # _clone <repo> <sha>
    local repo="$1" sha="$2" dir="${SRC}/$1"
    if [[ ! -d "${dir}/.git" ]]; then
      mkdir -p "${SRC}"
      git clone -q "https://github.com/redhat-data-and-ai/${repo}.git" "${dir}" \
        || die "could not clone ${repo}"
    fi
    git -C "${dir}" fetch -q --depth=1 origin "${sha}" 2>/dev/null || true
    git -C "${dir}" checkout -q "${sha}" || die "could not check out ${repo}@${sha}"
  }

  _load() { # _load <image> -- `kind load docker-image` does not see podman's
            # store, so go through an archive.
    local img="$1"
    local tar="${BUILD_DIR}/$(tr '/:' '__' <<<"${img}").tar"
    "${CE}" save -o "${tar}" "${img}" >/dev/null 2>&1 || die "could not save ${img}"
    kind load image-archive "${tar}" --name "${CLUSTER_NAME}" >/dev/null 2>&1 \
      || die "could not load ${img} into ${CLUSTER_NAME}"
    rm -f "${tar}"
  }

  if [[ "${sub}" == "all" || "${sub}" == "build" ]]; then
    need "${CE}"; need git
    step "cloning template-agent and template-ui at their pinned commits"
    _clone template-agent "${AGENT_SHA}"
    _clone template-ui    "${UI_SHA}"

    step "building template-ui"
    "${CE}" build -q -t localhost/template-ui:local \
      -f "${SRC}/template-ui/Containerfile" "${SRC}/template-ui" >/dev/null \
      || die "template-ui build failed"

    step "building template-agent"
    "${CE}" build -q -t localhost/template-agent:local \
      -f "${SRC}/template-agent/Containerfile" "${SRC}/template-agent" >/dev/null \
      || die "template-agent build failed"

    # The agent image ships an empty /app/config/agent: the Containerfile sets
    # CONFIG_PATH but never copies config in, so the agent exits with
    # "Missing required config files". The tree is nested, which ConfigMap
    # keys cannot express, so bake it as a layer.
    # The model is declared in PROMPT.md front matter, which is baked into
    # the image -- so it is rewritten here from AGENT_MODEL rather than
    # being a deploy-time env var.
    step "setting the agent model to ${AGENT_MODEL}"
    sed -i.bak -E "s|^model: .*|model: ${AGENT_MODEL}|" \
      "${SRC}/template-agent/config/agent/PROMPT.md"
    rm -f "${SRC}/template-agent/config/agent/PROMPT.md.bak"
    grep -q "^model: ${AGENT_MODEL}$" "${SRC}/template-agent/config/agent/PROMPT.md" \
      || die "could not set the model in PROMPT.md"

    step "baking the agent config and the OpenShell backend"
    # Declare the tools in PROMPT.md so the capability manifest admits
    # them: an unlisted tool is assembled into the graph and then filtered
    # back out by enforce_capability, which looks like the tool silently
    # not existing. All but the last are derived by FilesystemMiddleware
    # from the backend rather than written by us.
    #
    # Rewritten rather than appended-if-missing. A guard that skips when
    # the section is already there leaves an earlier build's wording in
    # place: that is how a prompt still telling the model "each call gets
    # a fresh sandbox" survived the move to a persistent session.
    local PROMPT_MD="${SRC}/template-agent/config/agent/PROMPT.md"
    sed -i.bak -E \
      '/^  - (execute|read_file|write_file|edit_file|ls|glob|grep|delete|openshell_[a-z_]+)$/d' \
      "${PROMPT_MD}"
    sed -i.bak -E 's|^tools:$|tools:\n  - execute\n  - read_file\n  - write_file\n  - edit_file\n  - ls\n  - glob\n  - grep\n  - delete\n  - openshell_reset_sandbox|' \
      "${PROMPT_MD}"
    rm -f "${PROMPT_MD}.bak"
    grep -q '^  - openshell_reset_sandbox$' "${PROMPT_MD}" \
      || die "could not add the sandbox tools to the PROMPT.md tools list"
    # The stock persona is a fitness assistant whose routing sends anything
    # non-health to "Out-of-scope -> Decline". The tools are wired and the
    # capability manifest admits them, but the model still refuses -- so
    # the prompt has to say code execution is in scope, or they are dead
    # weight in the UI. Our section is always last, so dropping everything
    # from its heading onwards leaves the upstream prompt intact.
    awk 'index($0, "## Running code (in scope)") == 1 { exit } { print }' \
      "${PROMPT_MD}" > "${PROMPT_MD}.new" && mv "${PROMPT_MD}.new" "${PROMPT_MD}"
    cat >> "${PROMPT_MD}" <<'PROMPTEOF'

## Running code (in scope)

You can run shell commands in a network-isolated sandbox with the
`execute` tool. This is IN SCOPE -- do not decline it as out-of-scope.

Use it when the user asks you to run code, compute something
programmatically, check a value, or inspect the sandbox environment.

- `execute` takes a shell command: `python3 -c '...'` to run Python, or
  any ordinary command.
- Report the tool's output verbatim. Do not invent output you did not get.
- `read_file`, `write_file`, `edit_file`, `ls`, `glob` and `grep` act on
  that same sandbox for any path outside /memories/, /reports/, /skills/
  and /data/.
- The sandbox is a long-lived session shared across calls, so state DOES
  persist: files, installed packages and anything written to disk are
  still there next time. Call `openshell_reset_sandbox` for a clean slate.
- It has no network access beyond DNS and no cluster credentials.
- If a tool returns an error, show it rather than guessing at a cause.
PROMPTEOF
    grep -q '## Running code (in scope)' "${PROMPT_MD}" \
      || die "could not add the code-execution section to PROMPT.md"

    cp "${ROOT_DIR}/apps/template-agent/patch/openshell_backend.py" \
       "${SRC}/template-agent/openshell_backend.py"
    "${CE}" build -q -t localhost/template-agent:local-config \
      -f "${ROOT_DIR}/apps/template-agent/patch/Containerfile.agent" \
      "${SRC}/template-agent" >/dev/null \
      || die "agent config/tools layer build failed"

    step "loading images into ${CLUSTER_NAME}"
    _load localhost/template-agent:local-config
    _load localhost/template-ui:local
    ok "images built and loaded"
  fi

  if [[ "${sub}" == "all" || "${sub}" == "deploy" ]]; then
    step "deploying the agent stack"
    kc get namespace "${NS}" >/dev/null 2>&1 || kc create namespace "${NS}" >/dev/null
    # A tenant, not platform: no platform.kind.local/component label, so
    # Kyverno polices it in full.
    kc label namespace "${NS}" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null

    # The UI refuses to start without COOKIE_SIGN (>=32 chars) and upstream's
    # overlay never supplies it. Generated once, reused on re-deploys.
    local cookie_file="${ROOT_DIR}/.secrets/ui-cookie-sign"
    [[ -s "${cookie_file}" ]] || { rand_alnum 48 > "${cookie_file}"; chmod 600 "${cookie_file}"; }
    kc -n "${NS}" create secret generic ui-secrets \
      --from-literal=COOKIE_SIGN="$(cat "${cookie_file}")" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null

    kc apply -k "${ROOT_DIR}/apps/template-agent" >/dev/null
    for d in pgvector redis agent ui; do
      kc -n "${NS}" rollout status "deployment/${d}" --timeout=300s >/dev/null \
        || warn "${d} did not become ready"
    done
    ok "agent stack ready at https://agent-ui.${BASE_DOMAIN}${URL_SUFFIX}"
    warn "the agent needs an OpenAI-compatible endpoint to answer prompts:"
    warn "  kubectl -n ${NS} set env deploy/agent VLLM_BASE_URL=... LLM_API_KEY=..."
  fi
}

cmd_secrets() {
  # Every credential this platform generated, in one place. `urls` prints the
  # handful you need to log in; this prints all of them, including the ones
  # that only matter when something is broken.
  #
  # Values come from .secrets/ (generated at install, gitignored) and from
  # the cluster for anything a chart minted itself.
  local S="${ROOT_DIR}/.secrets"
  _f()  { [[ -s "${S}/$1" ]] && cat "${S}/$1" || echo "(not generated)"; }
  _k()  { kc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null; }
  _row(){ printf '  %-30s %-42s %s\n' "$1" "$2" "$3"; }
  _hdr(){ printf '\n%s\n' "$(_c '1;34' "$1")"; }

  printf '\n%s\n' "$(_c '1;33' 'These are live credentials. They are printed in full below.')"

  _hdr 'single sign-on (Keycloak -- use these for every console)'
  _row "${SSO_ADMIN_USERNAME}"  "$(_f sso-admin-password)"  "group: platform-admins"
  _row "${SSO_VIEWER_USERNAME}" "$(_f sso-viewer-password)" "group: platform-viewers"

  _hdr 'break-glass (local logins, only when SSO is down -- make break-glass)'
  _row "keycloak admin console" "$(_f keycloak-admin-password)" "user: ${KEYCLOAK_ADMIN_USERNAME}"
  _row "grafana admin"          "$(_f grafana-admin-password)"  "user: admin"
  local argo; argo="$(_k argocd argocd-initial-admin-secret password)"
  _row "argo cd admin"          "${argo:-(rotated or disabled)}" "user: admin"

  _hdr 'registry'
  _row "$(_f registry-username)" "$(_f registry-password)" "localhost:${REGISTRY_HOST_PORT}"

  _hdr 'databases'
  _row "platform postgres (keycloak)" "$(_f keycloak-db-password)" "user: keycloak"
  _row "platform postgres (grafana)"  "$(_f grafana-db-password)"  "user: grafana"
  local apg; apg="$(_k template-agent agent-secrets POSTGRES_PASSWORD)"
  [[ -n "${apg}" ]] && _row "agent stack postgres" "${apg}" "user: $(_k template-agent agent-secrets POSTGRES_USER)"

  _hdr 'object store (S3 for Loki and Velero)'
  _row "$(_f s3-access-key)" "$(_f s3-secret-key)" "s3.storage.svc:8333"

  _hdr 'vault'
  if [[ -s "${S}/vault-unseal-keys.json" ]]; then
    _row "unseal keys" "${S}/vault-unseal-keys.json" "$(jq -r '.unseal_keys_b64 | length' "${S}/vault-unseal-keys.json" 2>/dev/null) shares, threshold 2"
    _row "root token" "$([[ -s "${S}/vault-root-token" ]] && echo "$(cat "${S}/vault-root-token")" || echo '(revoked -- sign in via Keycloak)')" ""
  else
    _row "vault" "(not initialised)" ""
  fi

  _hdr 'other'
  # Prefer the file, but fall back to the cluster: the Secret can exist
  # without the file if it was created before scripts/ops.sh agent-stack did.
  local cookie; cookie="$([[ -s "${S}/ui-cookie-sign" ]] && cat "${S}/ui-cookie-sign" || _k template-agent ui-secrets COOKIE_SIGN)"
  [[ -n "${cookie}" ]] && _row "agent UI cookie signing key" "${cookie}" "template-agent/ui-secrets"
  _row "oauth2-proxy cookie secret" "$(_f oauth2-proxy-cookie-secret)" ""

  printf '\n  %s\n' "All of the above live in .secrets/ (gitignored, chmod 600)."
  printf '  %s\n\n' "'make reset' regenerates every one of them."
}

cmd_agent_creds() {
  # Installs Google service account credentials for the agent's Vertex AI
  # model, as a SealedSecret so the JSON is encrypted in git and only the
  # cluster's sealed-secrets key can read it.
  #
  #   make agent-creds FILE=/path/to/service-account.json
  local src="${FILE:-$1}"
  [[ -n "${src}" ]] || die "usage: make agent-creds FILE=/path/to/service-account.json"
  [[ -s "${src}" ]]  || die "no such file: ${src}"
  jq -e '.type=="service_account" and has("project_id") and has("private_key")' "${src}" >/dev/null 2>&1 \
    || die "${src} does not look like a Google service account key (expected type=service_account)"

  local proj; proj="$(jq -r .project_id "${src}")"
  cp "${src}" "${ROOT_DIR}/.secrets/google-credentials.json"
  chmod 600 "${ROOT_DIR}/.secrets/google-credentials.json"
  ok "stored credentials for project ${proj} in .secrets/"

  kc get namespace template-agent >/dev/null 2>&1 \
    || die "the agent stack is not deployed -- run: make agent-stack"

  kc -n template-agent create secret generic agent-google-creds \
    --from-file=credentials.json="${src}" --dry-run=client -o yaml \
    > "${BUILD_DIR}/agent-google-creds.yaml"

  # Sealed, so Argo CD applies it from git like everything else.
  "${ROOT_DIR}/scripts/ops.sh" seal < "${BUILD_DIR}/agent-google-creds.yaml" \
    > "${ROOT_DIR}/apps/template-agent/google-creds-sealedsecret.yaml" \
    || die "could not seal the credentials"
  rm -f "${BUILD_DIR}/agent-google-creds.yaml"

  if ! grep -q 'google-creds-sealedsecret.yaml' "${ROOT_DIR}/apps/template-agent/kustomization.yaml"; then
    sed -i '' 's|  - ui-sealedsecret.yaml|  - ui-sealedsecret.yaml\n  - google-creds-sealedsecret.yaml|' \
      "${ROOT_DIR}/apps/template-agent/kustomization.yaml"
  fi
  ok "sealed into apps/template-agent/google-creds-sealedsecret.yaml"

  kc apply -k "${ROOT_DIR}/apps/template-agent" >/dev/null
  kc -n template-agent rollout restart deployment/agent >/dev/null
  kc -n template-agent rollout status deployment/agent --timeout=300s >/dev/null \
    && ok "agent restarted with Vertex AI credentials (project ${proj})"
  warn "commit apps/template-agent/google-creds-sealedsecret.yaml -- it is encrypted, not plaintext"
}

_usage() {
  echo "usage: $(basename "$0") <doctor|urls|secrets|status|token|seal|break-glass|demo|gitops|push|sign|openshell|agent-stack|agent-creds> [args]" >&2
  exit 2
}
[[ $# -ge 1 ]] || _usage
_sub="$1"; shift
case "${_sub}" in
  doctor) cmd_doctor "$@" ;;
  openshell) cmd_openshell "$@" ;;
  agent-stack) cmd_agent_stack "$@" ;;
  agent-creds) cmd_agent_creds "$@" ;;
  urls) cmd_urls "$@" ;;
  secrets) cmd_secrets "$@" ;;
  status) cmd_status "$@" ;;
  token) cmd_token "$@" ;;
  seal) cmd_seal "$@" ;;
  break-glass) cmd_break_glass "$@" ;;
  demo) cmd_demo "$@" ;;
  gitops) cmd_gitops "$@" ;;
  push) cmd_push "$@" ;;
  sign) cmd_sign "$@" ;;
  *) _usage ;;
esac
