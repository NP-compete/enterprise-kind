#!/usr/bin/env bash
# Installs the whole platform onto an existing cluster. Idempotent: re-run it
# after editing anything under platform/.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist -- run: make up"
kc cluster-info >/dev/null || die "cannot reach the cluster"

SECRETS_DIR="${ROOT_DIR}/.secrets"
mkdir -p "${SECRETS_DIR}" "${BUILD_DIR}/values"
chmod 700 "${SECRETS_DIR}"

# gen <file> [length] -- generate once, reuse forever so re-installs are stable.
gen() {
  local f="${SECRETS_DIR}/$1" len="${2:-24}"
  if [[ ! -s "${f}" ]]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}" > "${f}"
    chmod 600 "${f}"
  fi
  cat "${f}"
}

GRAFANA_ADMIN_PASSWORD="$(gen grafana-admin-password)"
KEYCLOAK_DB_PASSWORD="$(gen keycloak-db-password 32)"
# Identity credentials come from config.env so they are predictable and editable.
export KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD \
       SSO_ADMIN_USERNAME SSO_ADMIN_PASSWORD SSO_VIEWER_USERNAME SSO_VIEWER_PASSWORD
OIDC_SECRET_GRAFANA="$(gen oidc-secret-grafana 40)"
OIDC_SECRET_ARGOCD="$(gen oidc-secret-argocd 40)"
OIDC_SECRET_HEADLAMP="$(gen oidc-secret-headlamp 40)"
OIDC_SECRET_OAUTH2PROXY="$(gen oidc-secret-oauth2-proxy 40)"
OIDC_SECRET_VAULT="$(gen oidc-secret-vault 40)"
OAUTH2_PROXY_COOKIE_SECRET="$(gen oauth2-proxy-cookie-secret 32)"
export GRAFANA_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD \
       OIDC_SECRET_GRAFANA OIDC_SECRET_ARGOCD \
       OIDC_SECRET_HEADLAMP OIDC_SECRET_OAUTH2PROXY OAUTH2_PROXY_COOKIE_SECRET OIDC_SECRET_VAULT
export PLATFORM_CA_PEM_INDENTED=""
export REALM_CHECKSUM=""
export PORTAL_CONFIG_CHECKSUM=""
export REGISTRY_CONTAINER_IP=""
export S3_CONFIG_CHECKSUM=""
export S3_ACCESS_KEY=""
export S3_SECRET_KEY=""

# Substitute only our own variables so chart templating like $${__value} survives.
SUBST='${BASE_DOMAIN} ${URL_SUFFIX} ${CLUSTER_NAME} ${GRAFANA_ADMIN_PASSWORD}
       ${REGISTRY_NAME} ${REGISTRY_HOST_PORT} ${KEYCLOAK_ADMIN_PASSWORD}
       ${KEYCLOAK_ADMIN_USERNAME} ${SSO_ADMIN_USERNAME} ${SSO_VIEWER_USERNAME}
       ${KEYCLOAK_DB_PASSWORD} ${SSO_ADMIN_PASSWORD} ${SSO_VIEWER_PASSWORD}
       ${OIDC_SECRET_GRAFANA} ${OIDC_SECRET_ARGOCD} ${OIDC_SECRET_HEADLAMP}
       ${OIDC_SECRET_OAUTH2PROXY} ${OAUTH2_PROXY_COOKIE_SECRET} ${PLATFORM_CA_PEM_INDENTED}
       ${REALM_CHECKSUM} ${PORTAL_CONFIG_CHECKSUM} ${REGISTRY_CONTAINER_IP}
       ${S3_CONFIG_CHECKSUM} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} ${NODE_IMAGE_ETCD}'
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

log "adding/refreshing helm repos"
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
log "namespaces"
kc apply -f "${M}/namespaces.yaml" >/dev/null
ok "namespaces ready"

# Keycloak's secrets must exist before anything that mounts them starts.
log "identity secrets"
kc -n identity create secret generic keycloak-db \
  --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
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
kc apply -f "${M}/keycloak-postgres.yaml" >/dev/null
ok "identity secrets and database applied"

# ---------------------------------------------------------------- PKI
helm_install cert-manager cert-manager jetstack/cert-manager "${CHART_CERT_MANAGER}" "$(render "${V}/cert-manager.yaml")"
log "loading the platform CA into cert-manager"
[[ -s "${SECRETS_DIR}/platform-root-ca.crt" ]] || die "no platform CA -- run scripts/pki.sh"
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
helm_install velero velero vmware-tanzu/velero "${CHART_VELERO}" "$(render "${V}/velero.yaml")"
kc apply -f "$(render_manifest "${M}/etcd-backup.yaml")" >/dev/null
# Take one immediately rather than waiting up to 6h for the first scheduled
# run. This both gives a fresh cluster a real backup straight away and proves
# the whole snapshot+upload path works at install time instead of overnight.
if ! kc -n kube-system get job etcd-snapshot-initial >/dev/null 2>&1; then
  # `create job --from=cronjob` copies the CronJob's labels but sets no owner
  # reference, so the CronJob controller logs "Saw a job that the controller
  # did not create or forgot" on every reconcile. Strip the inherited labels.
  kc -n kube-system create job etcd-snapshot-initial --from=cronjob/etcd-snapshot \
    --dry-run=client -o json \
    | jq 'del(.metadata.labels) | .metadata.labels = {"app.kubernetes.io/name":"etcd-snapshot-initial","owner":"platform-team"}' \
    | kc apply -f - >/dev/null
  for _ in $(seq 1 30); do
    [[ "$(kc -n kube-system get job etcd-snapshot-initial -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]] && break
    sleep 10
  done
  if [[ "$(kc -n kube-system get job etcd-snapshot-initial -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
    ok "initial etcd snapshot taken and uploaded"
  else
    warn "initial etcd snapshot did not complete -- check: kubectl -n kube-system logs job/etcd-snapshot-initial"
  fi
fi
ok "backups: Velero schedules + 6-hourly etcd snapshots"

# ---------------------------------------------------------------- secrets
# Sealed Secrets lets secrets be committed to git in encrypted form, which is
# what makes the Argo CD path usable without plaintext in the repo. The
# controller's private key lives only in the cluster -- back it up (it is
# included in the Velero schedule) or sealed secrets become undecryptable.
log "sealed-secrets ${SEALED_SECRETS_VERSION}"
kc apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml" >/dev/null
wait_rollout kube-system deployment/sealed-secrets-controller
ok "sealed-secrets ready (seal with: make seal < secret.yaml)"

# ---------------------------------------------------------------- core
helm_install metrics-server kube-system metrics-server/metrics-server "${CHART_METRICS_SERVER}" "$(render "${V}/metrics-server.yaml")"
helm_install ingress-nginx ingress-nginx ingress-nginx/ingress-nginx "${CHART_INGRESS_NGINX}" "$(render "${V}/ingress-nginx.yaml")"

# In-cluster DNS for the public hostnames, needed for server-side OIDC calls.
"${ROOT_DIR}/scripts/cluster-dns.sh"

# ---------------------------------------------------------------- identity
wait_rollout identity statefulset/keycloak-postgres
helm_install keycloak identity codecentric/keycloakx "${CHART_KEYCLOAK}" "$(render "${V}/keycloak.yaml")"
"${ROOT_DIR}/scripts/keycloak-reconcile.sh"
# Make the API server trust Keycloak, so a Headlamp SSO login maps to a real
# Kubernetes identity. Must come after Keycloak is serving.
"${ROOT_DIR}/scripts/apiserver-oidc.sh"
helm_install oauth2-proxy identity oauth2-proxy/oauth2-proxy "${CHART_OAUTH2_PROXY}" "$(render "${V}/oauth2-proxy.yaml")"

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
"${ROOT_DIR}/scripts/vault-init.sh"
helm_install external-secrets external-secrets external-secrets/external-secrets \
  "${CHART_EXTERNAL_SECRETS}" "$(render "${V}/external-secrets.yaml")"
kc label namespace external-secrets platform.kind.local/component=secrets --overwrite >/dev/null
kc apply -f "${M}/external-secrets-store.yaml" >/dev/null
ok "Vault + External Secrets ready (https://vault.${BASE_DOMAIN}${URL_SUFFIX})"


# ---------------------------------------------------------------- observability
helm_install kps observability prometheus-community/kube-prometheus-stack "${CHART_KUBE_PROM_STACK}" "$(render "${V}/kube-prometheus-stack.yaml")"
helm_install loki observability grafana/loki "${CHART_LOKI}" "$(render "${V}/loki.yaml")"
helm_install tempo observability grafana/tempo "${CHART_TEMPO}" "$(render "${V}/tempo.yaml")"
helm_install alloy observability grafana/alloy "${CHART_ALLOY}" "$(render "${V}/alloy.yaml")"

kc apply -f "${M}/alert-sink.yaml" >/dev/null
kc apply -f "${M}/priority-classes.yaml" >/dev/null
ok "alert sink + priority classes applied"

log "installing platform dashboards"
kc apply -f "${ROOT_DIR}/platform/dashboards/" >/dev/null
ok "dashboards loaded"

# ---------------------------------------------------------------- governance
helm_install kyverno kyverno kyverno/kyverno "${CHART_KYVERNO}" "$(render "${V}/kyverno.yaml")"
kc apply -f "${M}/kyverno-policies.yaml" >/dev/null
ok "kyverno policies applied"

# ---------------------------------------------------------------- UIs
helm_install argocd argocd argo/argo-cd "${CHART_ARGOCD}" "$(render "${V}/argo-cd.yaml")"
helm_install headlamp headlamp headlamp/headlamp "${CHART_HEADLAMP}" "$(render "${V}/headlamp.yaml")"
kc apply -f "${M}/headlamp-admin.yaml" >/dev/null

log "platform portal"
PORTAL_RENDERED="$(render_manifest "${M}/portal.yaml")"
PORTAL_CONFIG_CHECKSUM="$(shasum -a 256 "${PORTAL_RENDERED}" | cut -c1-16)"
export PORTAL_CONFIG_CHECKSUM
# Re-render so the checksum annotation lands in the manifest that gets applied.
kc apply -f "$(render_manifest "${M}/portal.yaml")" >/dev/null
ok "portal at https://home.${BASE_DOMAIN}${URL_SUFFIX}"

log "registry UI"
REGISTRY_CONTAINER_IP="$("${ROOT_DIR}/scripts/registry.sh" ip)"
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

# ------------------------------------------------- second pass: ServiceMonitors
# These were held back on first install because the Prometheus CRDs did not exist yet.
log "enabling ServiceMonitors now that the Prometheus CRDs exist"
upgrade_sm() { # upgrade_sm <release> <ns> <chart> <version> <set...>
  local rel="$1" ns="$2" chart="$3" ver="$4"; shift 4
  local sets=(); for s in "$@"; do sets+=(--set "$s"); done
  helm upgrade "${rel}" "${chart}" --version "${ver}" -n "${ns}" --reuse-values \
    "${sets[@]}" --kube-context "${KUBECONTEXT}" --wait --timeout 10m >/dev/null
}
upgrade_sm metrics-server kube-system  metrics-server/metrics-server "${CHART_METRICS_SERVER}" serviceMonitor.enabled=true
upgrade_sm cert-manager   cert-manager jetstack/cert-manager          "${CHART_CERT_MANAGER}"   prometheus.servicemonitor.enabled=true
upgrade_sm ingress-nginx  ingress-nginx ingress-nginx/ingress-nginx   "${CHART_INGRESS_NGINX}"  controller.metrics.serviceMonitor.enabled=true
upgrade_sm tempo          observability grafana/tempo                 "${CHART_TEMPO}"          serviceMonitor.enabled=true
upgrade_sm alloy          observability grafana/alloy                 "${CHART_ALLOY}"          serviceMonitor.enabled=true
upgrade_sm keycloak       identity     codecentric/keycloakx          "${CHART_KEYCLOAK}"       serviceMonitor.enabled=true
upgrade_sm oauth2-proxy   identity     oauth2-proxy/oauth2-proxy      "${CHART_OAUTH2_PROXY}"   metrics.serviceMonitor.enabled=true
upgrade_sm argocd         argocd       argo/argo-cd                   "${CHART_ARGOCD}" \
  server.metrics.serviceMonitor.enabled=true \
  controller.metrics.serviceMonitor.enabled=true \
  repoServer.metrics.serviceMonitor.enabled=true
ok "ServiceMonitors enabled"

"${ROOT_DIR}/scripts/urls.sh"
