#!/usr/bin/env bash
# Installs the whole platform onto an existing cluster. Idempotent: re-run it
# after editing anything under platform/.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A failed install is almost always resumable: every step is idempotent and
# re-running picks up where it stopped. Say so, instead of leaving the user
# staring at the last 40 lines of helm output.
_on_fail() {
  local rc=$?
  [[ ${rc} -eq 0 ]] && return 0
  hint "the install stopped partway through. It is idempotent -- re-running resumes:" \
       "  make install" \
       "" \
       "if that fails the same way:" \
       "  make doctor        # names the problem and the fix" \
       "  kubectl get pods -A | grep -v Running"
  return ${rc}
}
trap _on_fail EXIT

cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist -- run: make up"
kc cluster-info >/dev/null || die "cannot reach the cluster"

SECRETS_DIR="${ROOT_DIR}/.secrets"
mkdir -p "${SECRETS_DIR}" "${BUILD_DIR}/values"
chmod 700 "${SECRETS_DIR}"

# gen <file> [length] -- generate once, reuse forever so re-installs are stable.
gen() {
  local f="${SECRETS_DIR}/$1" len="${2:-24}"
  if [[ ! -s "${f}" ]]; then
    rand_alnum "${len}" > "${f}"
    chmod 600 "${f}"
  fi
  cat "${f}"
}

GRAFANA_ADMIN_PASSWORD="$(gen grafana-admin-password)"
KEYCLOAK_DB_PASSWORD="$(gen keycloak-db-password 32)"
GRAFANA_DB_PASSWORD="$(gen grafana-db-password 32)"

# Identity credentials: usernames are config, passwords are generated unless
# config.env pins one. `gen` only writes when the file is empty, so a password
# generated on the first install survives every later run -- the cluster has
# stable credentials that were never committed to the repo.
gen_or_env() { # gen_or_env <secrets-file> <value-from-config> [length]
  local f="${SECRETS_DIR}/$1" v="$2" len="${3:-20}"
  if [[ -n "${v}" ]]; then
    printf '%s' "${v}" > "${f}"; chmod 600 "${f}"; printf '%s' "${v}"; return
  fi
  gen "$1" "${len}"
}
KEYCLOAK_ADMIN_PASSWORD="$(gen_or_env keycloak-admin-password "${KEYCLOAK_ADMIN_PASSWORD:-}")"
SSO_ADMIN_PASSWORD="$(gen_or_env sso-admin-password  "${SSO_ADMIN_PASSWORD:-}")"
SSO_VIEWER_PASSWORD="$(gen_or_env sso-viewer-password "${SSO_VIEWER_PASSWORD:-}")"
export KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD \
       SSO_ADMIN_USERNAME SSO_ADMIN_PASSWORD SSO_VIEWER_USERNAME SSO_VIEWER_PASSWORD
OIDC_SECRET_GRAFANA="$(gen oidc-secret-grafana 40)"
OIDC_SECRET_ARGOCD="$(gen oidc-secret-argocd 40)"
OIDC_SECRET_HEADLAMP="$(gen oidc-secret-headlamp 40)"
OIDC_SECRET_OAUTH2PROXY="$(gen oidc-secret-oauth2-proxy 40)"
OIDC_SECRET_VAULT="$(gen oidc-secret-vault 40)"
OIDC_SECRET_TEMPLATE_AGENT="$(gen oidc-secret-template-agent 40)"
OAUTH2_PROXY_COOKIE_SECRET="$(gen oauth2-proxy-cookie-secret 32)"
export GRAFANA_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD GRAFANA_DB_PASSWORD \
       OIDC_SECRET_GRAFANA OIDC_SECRET_ARGOCD \
       OIDC_SECRET_HEADLAMP OIDC_SECRET_OAUTH2PROXY OAUTH2_PROXY_COOKIE_SECRET OIDC_SECRET_VAULT \
       OIDC_SECRET_TEMPLATE_AGENT
export PLATFORM_CA_PEM_INDENTED=""
export REALM_CHECKSUM=""
export PORTAL_CONFIG_CHECKSUM=""
export REGISTRY_CONTAINER_IP=""
export S3_CONFIG_CHECKSUM=""
export COSIGN_PUBLIC_KEY_INDENTED=""
export PLATFORM_CA_PEM_INDENTED6=""
export S3_ACCESS_KEY=""
export S3_SECRET_KEY=""

# Substitute only our own variables so chart templating like $${__value} and
# Grafana's $__file{...} survive. The list lives in lib.sh, shared with
# scripts/lint.sh so CI renders exactly what the installer does.
SUBST="${PLATFORM_SUBST}"
render() {
  local dst="${BUILD_DIR}/values/$(basename "$1")"
  envsubst "${SUBST}" < "$1" > "${dst}"
  printf '%s' "${dst}"
}
render_manifest() {
  local dst="${BUILD_DIR}/$(basename "$1")"
  envsubst "${SUBST}" < "$1" > "${dst}"
  printf '%s' "${dst}"
}

V="${ROOT_DIR}/platform/values"
M="${ROOT_DIR}/platform/manifests"

step "adding/refreshing helm repos"
helm repo add ingress-nginx        https://kubernetes.github.io/ingress-nginx            >/dev/null 2>&1 || true
helm repo add jetstack             https://charts.jetstack.io                            >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts    >/dev/null 2>&1 || true
helm repo add grafana              https://grafana.github.io/helm-charts                 >/dev/null 2>&1 || true
helm repo add argo                 https://argoproj.github.io/argo-helm                  >/dev/null 2>&1 || true
helm repo add headlamp             https://kubernetes-sigs.github.io/headlamp/           >/dev/null 2>&1 || true
helm repo add metrics-server       https://kubernetes-sigs.github.io/metrics-server/     >/dev/null 2>&1 || true
helm repo add kyverno              https://kyverno.github.io/kyverno/                    >/dev/null 2>&1 || true
helm repo add codecentric          https://codecentric.github.io/helm-charts             >/dev/null 2>&1 || true
helm repo add oauth2-proxy         https://oauth2-proxy.github.io/manifests              >/dev/null 2>&1 || true
helm repo update >/dev/null

# Priority classes must exist before anything references them.
kc apply -f "${M}/priority-classes.yaml" >/dev/null 2>&1 || true
# ---------------------------------------------------- prometheus-operator CRDs
# Applied before any chart, so every component can create its ServiceMonitor
# on first install. Without this the CRDs only arrive with kube-prometheus-
# stack, and seven charts had to be installed with serviceMonitor disabled
# and then upgraded again at the end -- seven extra `helm upgrade --wait`
# cycles, several minutes, for a boolean.
step "prometheus-operator CRDs"
CRD_DIR="${BUILD_DIR}/kps-crds"
if [[ ! -d "${CRD_DIR}" ]]; then
  rm -rf "${BUILD_DIR}/kps-chart"; mkdir -p "${BUILD_DIR}/kps-chart"
  helm pull prometheus-community/kube-prometheus-stack \
    --version "${CHART_KUBE_PROM_STACK}" --untar --untardir "${BUILD_DIR}/kps-chart" >/dev/null
  mv "${BUILD_DIR}/kps-chart/kube-prometheus-stack/charts/crds/crds" "${CRD_DIR}"
fi
# --server-side: these CRDs exceed the 256KB annotation limit that
# client-side apply uses to store last-applied-configuration.
kc apply --server-side --force-conflicts -f "${CRD_DIR}" >/dev/null
kc wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=60s >/dev/null
ok "monitoring CRDs established"

step "namespaces"
kc apply -f "${M}/namespaces.yaml" >/dev/null
ok "namespaces ready"

# ---------------------------------------------------------------- database
# CloudNativePG first: the Postgres cluster has to exist before Keycloak, and
# the operator has to exist before the Cluster resource can be applied.
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null 2>&1 || true
helm_install cnpg cnpg-system cnpg/cloudnative-pg "${CHART_CNPG}" "$(render "${V}/cnpg.yaml")"
# The Cluster CRD is registered asynchronously after the operator rolls out.
for _ in $(seq 1 30); do
  kc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 && break
  sleep 2
done
kc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 \
  || die "CloudNativePG CRDs never registered"

# Keycloak's secrets must exist before anything that mounts them starts.
step "identity secrets"
kc -n identity create secret generic keycloak-db \
  --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
# CloudNativePG reads the bootstrap owner's credentials from a basic-auth
# secret, which is a different shape from the single-key one Keycloak mounts.
kc -n identity create secret generic platform-pg-keycloak \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=keycloak --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n identity create secret generic keycloak-bootstrap-admin \
  --from-literal=username="${KEYCLOAK_ADMIN_USERNAME}" --from-literal=password="${KEYCLOAK_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
REALM_RENDERED="$(render_manifest "${M}/keycloak-realm.json")"
kc -n identity create secret generic keycloak-realm \
  --from-file=platform-realm.json="${REALM_RENDERED}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
# Rolls the Keycloak pod whenever the realm changes, so --import-realm re-runs.
REALM_CHECKSUM="$(shasum -a 256 "${REALM_RENDERED}" | cut -c1-16)"
export REALM_CHECKSUM
kc apply -f "$(render_manifest "${M}/postgres-cluster.yaml")" >/dev/null
step "waiting for the Postgres cluster to reach ${PG_INSTANCES} healthy instances"
for _ in $(seq 1 90); do
  ready="$(kc -n identity get cluster platform-pg \
           -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
  [[ "${ready}" == "${PG_INSTANCES}" ]] && break
  sleep 10
done
[[ "${ready:-0}" == "${PG_INSTANCES}" ]] \
  || die "Postgres cluster has ${ready:-0}/${PG_INSTANCES} instances ready"
# postInitSQL created the grafana role without a password (it only runs on
# first bootstrap). Setting it here every run makes this the rotation path
# too, rather than a one-shot that drifts from the secret.
# Which pod is primary is decided by the operator and changes after a
# failover, so ask rather than assuming platform-pg-1.
PG_PRIMARY="$(kc -n identity get pod -l 'cnpg.io/cluster=platform-pg,cnpg.io/instanceRole=primary' \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PG_PRIMARY}" ]] || die "no Postgres primary found in the platform-pg cluster"
kc -n identity exec "${PG_PRIMARY}" -c postgres -- \
  psql -v ON_ERROR_STOP=1 -q -c \
  "ALTER ROLE grafana WITH PASSWORD '${GRAFANA_DB_PASSWORD}';" >/dev/null \
  || die "could not set the grafana database password"
ok "Postgres cluster ready (${PG_INSTANCES} instances, primary ${PG_PRIMARY}, automatic failover)"

# ---------------------------------------------------------------- PKI
helm_install cert-manager cert-manager jetstack/cert-manager "${CHART_CERT_MANAGER}" "$(render "${V}/cert-manager.yaml")"
step "loading the platform CA into cert-manager"
[[ -s "${SECRETS_DIR}/platform-root-ca.crt" ]] || die "no platform CA -- run scripts/cluster.sh pki"
kc -n cert-manager create secret tls platform-root-ca \
  --cert="${SECRETS_DIR}/platform-root-ca.crt" \
  --key="${SECRETS_DIR}/platform-root-ca.key" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$(render_manifest "${M}/cert-manager-issuers.yaml")" >/dev/null

CA_PEM="$(cat "${SECRETS_DIR}/platform-root-ca.crt")"
PLATFORM_CA_PEM_INDENTED="$(sed 's/^/        /' <<<"${CA_PEM}")"
export PLATFORM_CA_PEM_INDENTED
# Any namespace whose workloads must validate a platform-CA certificate needs
# this. Namespaces are created here if absent so ordering never matters.
for ns in observability argocd headlamp identity ingress-nginx registry storage portal; do
  # `kubectl apply` of a bare Namespace STRIPS labels a previous apply set --
  # that silently removed platform.kind.local/component from observability and
  # dropped it out of every policy exclusion. Only create when truly absent.
  kc get namespace "${ns}" >/dev/null 2>&1 || kc create namespace "${ns}" >/dev/null
  kc -n "${ns}" create configmap platform-ca --from-literal=ca.crt="${CA_PEM}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
done
kc -n observability create secret generic grafana-oidc \
  --from-literal=client_secret="${OIDC_SECRET_GRAFANA}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
# Read back with $__file{} from grafana.ini; the chart refuses literal
# secrets there.
kc -n observability create secret generic grafana-db \
  --from-literal=password="${GRAFANA_DB_PASSWORD}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "ClusterIssuer platform-ca ready; CA distributed to 8 namespaces"

# ---------------------------------------------------------------- object store
# S3 for Loki, Tempo, Velero and Postgres backups.
S3_ACCESS_KEY="$(gen s3-access-key 20)"
S3_SECRET_KEY="$(gen s3-secret-key 40)"
export S3_ACCESS_KEY S3_SECRET_KEY
kc get namespace storage >/dev/null 2>&1 || kc create namespace storage >/dev/null
cat > "${BUILD_DIR}/s3.json" <<JSON
{
  "identities": [
    {
      "name": "platform",
      "credentials": [{ "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }],
      "actions": ["Admin", "Read", "Write", "List", "Tagging"]
    }
  ]
}
JSON
chmod 600 "${BUILD_DIR}/s3.json"
kc -n storage create secret generic object-store-s3-config \
  --from-file=s3.json="${BUILD_DIR}/s3.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
S3_CONFIG_CHECKSUM="$(shasum -a 256 "${BUILD_DIR}/s3.json" | cut -c1-16)"
export S3_CONFIG_CHECKSUM
# Credentials in the form each consumer expects.
for ns in observability velero; do
  kc get namespace "${ns}" >/dev/null 2>&1 || kc create namespace "${ns}" >/dev/null
  # Velero's node-agent mounts hostPath to read pod volumes for filesystem
  # backups, which the cluster-wide baseline default forbids.
  if [[ "${ns}" == "velero" ]]; then
    kc label namespace velero \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/warn=privileged \
      pod-security.kubernetes.io/audit=privileged \
      platform.kind.local/component=backup --overwrite >/dev/null
  fi
  kc -n "${ns}" create secret generic object-store-credentials \
    --from-literal=AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    --from-literal=access_key_id="${S3_ACCESS_KEY}" \
    --from-literal=secret_access_key="${S3_SECRET_KEY}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
done
kc apply -f "$(render_manifest "${M}/object-store.yaml")" >/dev/null
wait_rollout storage statefulset/object-store
ok "object store ready (s3.storage.svc.cluster.local:8333)"

# Velero wants an AWS credentials *file*, not flat env vars.
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
  "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" > "${BUILD_DIR}/velero-cloud"
chmod 600 "${BUILD_DIR}/velero-cloud"
kc -n velero create secret generic velero-object-store \
  --from-file=cloud="${BUILD_DIR}/velero-cloud" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm_install_nw velero velero vmware-tanzu/velero "${CHART_VELERO}" "$(render "${V}/velero.yaml")"
kc apply -f "$(render_manifest "${M}/etcd-backup.yaml")" >/dev/null
# Take one immediately rather than waiting up to 6h for the first scheduled
# run. This both gives a fresh cluster a real backup straight away and proves
# the whole snapshot+upload path works at install time instead of overnight.
# Kick off an immediate snapshot so a fresh cluster has a real backup and the
# snapshot+upload path is exercised at install time. Deliberately NOT waited
# on: nothing later depends on it, and the poll loop cost up to five minutes
# of wall clock. `make smoke` verifies a snapshot actually landed.
if ! kc -n kube-system get job etcd-snapshot-initial >/dev/null 2>&1; then
  # `create job --from=cronjob` copies the CronJob's labels but sets no owner
  # reference, so the CronJob controller logs "Saw a job that the controller
  # did not create or forgot" on every reconcile. Strip the inherited labels.
  kc -n kube-system create job etcd-snapshot-initial --from=cronjob/etcd-snapshot \
    --dry-run=client -o json \
    | jq 'del(.metadata.labels) | .metadata.labels = {"app.kubernetes.io/name":"etcd-snapshot-initial","owner":"platform-team"}' \
    | kc apply -f - >/dev/null
  ok "initial etcd snapshot started (runs in the background)"
fi
ok "backups: Velero schedules + 6-hourly etcd snapshots"

# ---------------------------------------------------------------- secrets
# Sealed Secrets lets secrets be committed to git in encrypted form, which is
# what makes the Argo CD path usable without plaintext in the repo. The
# controller's private key lives only in the cluster -- back it up (it is
# included in the Velero schedule) or sealed secrets become undecryptable.
step "sealed-secrets ${SEALED_SECRETS_VERSION}"
kc apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml" >/dev/null
wait_rollout kube-system deployment/sealed-secrets-controller
ok "sealed-secrets ready (seal with: make seal < secret.yaml)"

# ---------------------------------------------------------------- core
helm_install_nw metrics-server kube-system metrics-server/metrics-server "${CHART_METRICS_SERVER}" "$(render "${V}/metrics-server.yaml")"
helm_install ingress-nginx ingress-nginx ingress-nginx/ingress-nginx "${CHART_INGRESS_NGINX}" "$(render "${V}/ingress-nginx.yaml")"

# In-cluster DNS for the public hostnames, needed for server-side OIDC calls.
"${ROOT_DIR}/scripts/cluster.sh" dns

# No load balancer. MetalLB cost 654 MiB across 14 pods (a speaker per node
# plus the controller) to hand out one VIP that only the host ever used, and
# the host reaches ingress through kind's published ports anyway. Services of
# type LoadBalancer will stay <pending> on this cluster -- that is expected.

# ---------------------------------------------------------------- identity
# The Postgres cluster was already waited on above.
helm_install keycloak identity codecentric/keycloakx "${CHART_KEYCLOAK}" "$(render "${V}/keycloak.yaml")"
"${ROOT_DIR}/scripts/identity.sh" keycloak
# Make the API server trust Keycloak, so a Headlamp SSO login maps to a real
# Kubernetes identity. Must come after Keycloak is serving.
"${ROOT_DIR}/scripts/identity.sh" apiserver
helm_install_nw oauth2-proxy identity oauth2-proxy/oauth2-proxy "${CHART_OAUTH2_PROXY}" "$(render "${V}/oauth2-proxy.yaml")"

# ---------------------------------------------------------------- vault
# Vault is the secret store of record; Sealed Secrets remains for the GitOps
# path (secrets committed to a repo). They solve different problems.
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
kc get namespace vault >/dev/null 2>&1 || kc create namespace vault >/dev/null
kc label namespace vault platform.kind.local/component=secrets --overwrite >/dev/null
helm upgrade --install vault hashicorp/vault --version "${CHART_VAULT}" \
  --namespace vault --kube-context "${KUBECONTEXT}" \
  -f "$(render "${V}/vault.yaml")" --timeout 10m >/dev/null
"${ROOT_DIR}/scripts/identity.sh" vault
helm_install external-secrets external-secrets external-secrets/external-secrets \
  "${CHART_EXTERNAL_SECRETS}" "$(render "${V}/external-secrets.yaml")"
kc label namespace external-secrets platform.kind.local/component=secrets --overwrite >/dev/null
kc apply -f "${M}/external-secrets-store.yaml" >/dev/null
ok "Vault + External Secrets ready (https://vault.${BASE_DOMAIN}${URL_SUFFIX})"


# ---------------------------------------------------------------- observability
# kps, loki and alloy do not depend on each other at install time -- alloy
# only talks to loki once both are running -- so they go up together.
helm_install_nw kps observability prometheus-community/kube-prometheus-stack "${CHART_KUBE_PROM_STACK}" "$(render "${V}/kube-prometheus-stack.yaml")"
helm_install_nw loki observability grafana/loki "${CHART_LOKI}" "$(render "${V}/loki.yaml")"
helm_install_nw tempo observability grafana/tempo "${CHART_TEMPO}" "$(render "${V}/tempo.yaml")"
helm_install_nw alloy observability grafana/alloy "${CHART_ALLOY}" "$(render "${V}/alloy.yaml")"

kc apply -f "${M}/alert-sink.yaml" >/dev/null
kc apply -f "${M}/priority-classes.yaml" >/dev/null
ok "alert sink + priority classes applied"

# Budgets for the manifest-defined components; the charts bring their own.
kc apply -f "${M}/pdbs.yaml" >/dev/null
ok "pod disruption budgets applied"

step "installing platform dashboards"
kc apply -f "${ROOT_DIR}/platform/dashboards/" >/dev/null
ok "dashboards loaded"

# ---------------------------------------------------------------- governance
PLATFORM_CA_PEM_INDENTED6="$(sed 's/^/      /' "${SECRETS_DIR}/platform-root-ca.crt")"
export PLATFORM_CA_PEM_INDENTED6
kc get namespace kyverno >/dev/null 2>&1 || kc create namespace kyverno >/dev/null
kc -n kyverno create secret docker-registry registry-creds \
  --docker-server="${REGISTRY_NAME}:5000" \
  --docker-username="$(cat "${SECRETS_DIR}/registry-username")" \
  --docker-password="$(cat "${SECRETS_DIR}/registry-password")" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
helm_install kyverno kyverno kyverno/kyverno "${CHART_KYVERNO}" "$(render "${V}/kyverno.yaml")"
# `helm --wait` returns before the webhook actually answers: Service
# endpoints and the webhook CA bundle land a moment later, and applying
# policies in that window fails with "connection refused" from policymutate.
step "waiting for the Kyverno webhook to serve"
for _ in $(seq 1 60); do
  kc -n kyverno get endpoints kyverno-svc \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q . && break
  sleep 5
done
# Endpoints are necessary but not sufficient; retry the real apply.
for attempt in $(seq 1 30); do
  if err="$(kc apply -f "${M}/kyverno-policies.yaml" 2>&1 >/dev/null)"; then
    break
  fi
  grep -q 'failed calling webhook\|connection refused\|no endpoints' <<<"${err}" \
    || die "applying kyverno policies failed: ${err}"
  [[ ${attempt} -eq 30 ]] && die "kyverno webhook never became available: ${err}"
  sleep 5
done
# Image-signature enforcement needs the cosign public key inlined.
if [[ -s "${SECRETS_DIR}/cosign.pub" ]]; then
  COSIGN_PUBLIC_KEY_INDENTED="$(sed 's/^/                      /' "${SECRETS_DIR}/cosign.pub")"
  export COSIGN_PUBLIC_KEY_INDENTED
  kc apply -f "$(render_manifest "${M}/kyverno-image-verify.yaml")" >/dev/null
  ok "image signature verification enforced for the local registry"
else
  warn "no cosign key at ${SECRETS_DIR}/cosign.pub -- run scripts/ops.sh sign first"
fi
ok "kyverno policies applied"

# ---------------------------------------------------------------- UIs
helm_install_nw argocd argocd argo/argo-cd "${CHART_ARGOCD}" "$(render "${V}/argo-cd.yaml")"
helm_install_nw headlamp headlamp headlamp/headlamp "${CHART_HEADLAMP}" "$(render "${V}/headlamp.yaml")"
kc apply -f "${M}/headlamp-admin.yaml" >/dev/null

step "platform portal"
PORTAL_RENDERED="$(render_manifest "${M}/portal.yaml")"
PORTAL_CONFIG_CHECKSUM="$(shasum -a 256 "${PORTAL_RENDERED}" | cut -c1-16)"
export PORTAL_CONFIG_CHECKSUM
# Re-render so the checksum annotation lands in the manifest that gets applied.
kc apply -f "$(render_manifest "${M}/portal.yaml")" >/dev/null
ok "portal at https://home.${BASE_DOMAIN}${URL_SUFFIX}"

step "registry UI"
REGISTRY_CONTAINER_IP="$("${ROOT_DIR}/scripts/cluster.sh" registry ip)"
[[ -n "${REGISTRY_CONTAINER_IP}" ]] || die "could not read ${REGISTRY_NAME}'s address on the kind network"
export REGISTRY_CONTAINER_IP
kc apply -f "$(render_manifest "${M}/registry-ui.yaml")" >/dev/null
ok "registry UI at https://registry.${BASE_DOMAIN}${URL_SUFFIX} -> ${REGISTRY_CONTAINER_IP}:5000"

# Calico ships Goldmane + Whisker (network flow aggregation and UI); expose it.
if kc -n calico-system get svc whisker >/dev/null 2>&1; then
  kc apply -f "$(render_manifest "${M}/whisker-ingress.yaml")" >/dev/null
  ok "network flow UI at https://flows.${BASE_DOMAIN}${URL_SUFFIX}"
fi

# ---------------------------------------------------------------- tenant
# No Trivy Operator and no KEDA. Trivy alone was 255 MiB resident plus a scan
# Job per workload; KEDA was 172 MiB across six pods for autoscaling that
# nothing in this cluster uses. Both are reinstated by uncommenting their
# blocks in git history if the footprint budget ever grows.

# ---------------------------------------------------------------- openshell
# Agent Sandbox (kubernetes-sigs) provides the Sandbox CRD and controller
# that OpenShell drives; it has to exist before the chart installs.
step "agent-sandbox ${AGENT_SANDBOX_VERSION}"
# The namespace must exist AND carry the platform exemption label before the
# bundle is applied: the upstream controller Deployment declares no resource
# requests, so require-resource-requests rejects it at admission otherwise.
# Server-side apply preserves labels owned by a different field manager, so
# the bundle's own Namespace object will not strip this.
kc get namespace agent-sandbox-system >/dev/null 2>&1 \
  || kc create namespace agent-sandbox-system >/dev/null
kc label namespace agent-sandbox-system \
  platform.kind.local/component=sandboxing --overwrite >/dev/null
kc apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml" >/dev/null
kc wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=90s >/dev/null
# Deployment name is not stable across releases; wait on whatever it shipped.
kc -n agent-sandbox-system wait --for=condition=Available deployment --all --timeout=180s >/dev/null \
  || warn "agent-sandbox controller did not report Available"
ok "agent-sandbox ready"

for ns in openshell openshell-sandboxes; do
  kc get namespace "${ns}" >/dev/null 2>&1 || kc create namespace "${ns}" >/dev/null
done
# The gateway is platform infrastructure, so it is excluded from tenant
# policy like every other platform namespace. The sandbox namespace is NOT:
# sandboxes are untrusted workloads and must be policed like tenants.
kc label namespace openshell platform.kind.local/component=sandboxing --overwrite >/dev/null
kc label namespace openshell-sandboxes \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null

helm_install openshell openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  "${CHART_OPENSHELL}" "$(render "${V}/openshell.yaml")"
# The supervisor pods run in sandboxNamespace but mount the gateway's
# client TLS secret, which the chart only creates in the release namespace.
# With both in one namespace that is invisible; we split them on purpose so
# sandboxes stay policed by Kyverno, which makes the secret a cross-namespace
# dependency the chart does not handle. Without this the supervisor sits in
# ContainerCreating with "secret openshell-client-tls not found" and the
# gateway rolls the sandbox back as a failed bootstrap.
for _ in $(seq 1 30); do
  kc -n openshell get secret openshell-client-tls >/dev/null 2>&1 && break
  sleep 5
done
if kc -n openshell get secret openshell-client-tls >/dev/null 2>&1; then
  kc -n openshell get secret openshell-client-tls -o json \
    | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,
              .metadata.creationTimestamp,.metadata.ownerReferences,
              .metadata.managedFields,.metadata.annotations)' \
    | kc -n openshell-sandboxes apply -f - >/dev/null
  ok "client TLS replicated into openshell-sandboxes (supervisor needs it there)"
else
  warn "openshell-client-tls never appeared; sandboxes will fail to bootstrap"
fi

ok "openshell gateway ready (make openshell)"

kc apply -f "${M}/platform-quotas.yaml" >/dev/null
kc apply -f "${M}/tenant-namespace.yaml" >/dev/null
# Pulling from the registry now needs credentials (containerd ignores auth in
# hosts.toml). Attach them to the tenant's default ServiceAccount so ordinary
# workloads do not each have to declare imagePullSecrets.
REG_USER="$(cat "${SECRETS_DIR}/registry-username")"
REG_PASS="$(cat "${SECRETS_DIR}/registry-password")"
for ns in apps default; do
  kc -n "${ns}" create secret docker-registry registry-creds \
    --docker-server="localhost:${REGISTRY_HOST_PORT}" \
    --docker-username="${REG_USER}" --docker-password="${REG_PASS}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "${ns}" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"registry-creds"}]}' >/dev/null 2>&1 || true
done
ok "registry pull credentials attached to apps/default ServiceAccounts"
ok "tenant namespace 'apps' ready"

wait_all_ready
step_report

"${ROOT_DIR}/scripts/ops.sh" urls
