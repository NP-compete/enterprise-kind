#!/usr/bin/env bash
# End-to-end verification: control plane, ingress+TLS, metrics, logs, traces,
# policy, registry. Exits non-zero on the first hard failure.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pass=0; fail=0
suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"

check() { # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  \033[1;32m✓\033[0m %s\n' "${name}"; pass=$((pass+1));
  else printf '  \033[1;31m✗\033[0m %s\n' "${name}"; fail=$((fail+1)); fi
}

http() { curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "$1" | grep -qE "$2"; }

echo; log "control plane"
check "all nodes Ready"              bash -c "! kubectl --context ${KUBECONTEXT} get nodes --no-headers | grep -v ' Ready '"
check "metrics-server serving"       kc top nodes
check "audit log being written"      bash -c "${CE} exec ${CLUSTER_NAME}-control-plane test -s /var/log/kubernetes/audit.log"
check "PodSecurity blocks privileged" bash -c "! kubectl --context ${KUBECONTEXT} -n apps run smoke-priv --image=busybox:1.36 --privileged --restart=Never --command -- true"

echo; log "ingress and PKI"
check "ClusterIssuer platform-ca ready" bash -c "kubectl --context ${KUBECONTEXT} get clusterissuer platform-ca -o jsonpath='{.status.conditions[0].status}' | grep -q True"
"${ROOT_DIR}/scripts/trust-ca.sh" export >/dev/null 2>&1 || true
CA="${ROOT_DIR}/.secrets/platform-root-ca.crt"
for host in grafana prometheus alertmanager argocd headlamp; do
  check "https://${host}.${BASE_DOMAIN} responds" http "https://${host}.${BASE_DOMAIN}${suffix}/" '200|302|301|307|401|403'
  check "  └ certificate chains to the platform CA" bash -c \
    "curl -sS --cacert '${CA}' --max-time 20 -o /dev/null 'https://${host}.${BASE_DOMAIN}${suffix}/'"
done

echo; log "observability"
# Prometheus sits behind oauth2-proxy, so its ingress returns a 302 to the
# login flow; health has to be probed through the API server instead.
check "Prometheus healthy" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/-/healthy' | grep -qi healthy"
check "Grafana healthy"    http "https://grafana.${BASE_DOMAIN}${suffix}/api/health" '200'
# Probed through the API server proxy: no curl/wget needed inside the images.
check "Prometheus scraping every kubelet" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/query?query=up%7Bjob%3D%22kubelet%22%7D' | jq -e '[.data.result[] | select(.value[1]==\"1\")] | length >= 4'"
check "Prometheus has no down targets" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/targets?state=active' | jq -e '[.data.activeTargets[] | select(.health==\"down\")] | length == 0'"
check "Loki is ready" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/loki:3100/proxy/ready' | grep -qi ready"
check "Loki has ingested pod logs" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/loki-gateway:80/proxy/loki/api/v1/label/namespace/values' | jq -e '.data | length > 3'"
check "Tempo is ready" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/tempo:3200/proxy/ready' | grep -qi ready"
check "Grafana datasources reachable" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-grafana:80/proxy/api/health' | jq -e '.database == \"ok\"'"
check "Alloy running on every node" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n observability get ds alloy -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context ${KUBECONTEXT} -n observability get ds alloy -o jsonpath='{.status.desiredNumberScheduled}')\""

echo; log "durability"
check "object store serving S3" bash -c \
  "kubectl --context ${KUBECONTEXT} -n storage exec object-store-0 -- wget -qO- http://localhost:8333/status >/dev/null"
for b in loki tempo velero postgres etcd; do
  check "  bucket '${b}' exists" bash -c \
    "kubectl --context ${KUBECONTEXT} -n storage exec object-store-0 -- sh -c \"printf 'fs.ls /buckets\\n' | weed shell -master=localhost:9333 -filer=localhost:8888 2>/dev/null\" | grep -qw ${b}"
done
check "Loki chunks landing in object storage" bash -c \
  "kubectl --context ${KUBECONTEXT} -n storage exec object-store-0 -- sh -c \"printf 'fs.ls /buckets/loki\\n' | weed shell -master=localhost:9333 -filer=localhost:8888 2>/dev/null\" | grep -qv '^$'"
check "Velero backup location Available" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n velero get bsl default -o jsonpath='{.status.phase}')\" = Available"
check "Velero backup schedules enabled" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n velero get schedules -o jsonpath='{.items[*].status.phase}' | tr ' ' '\\n' | grep -c Enabled)\" -ge 2"
check "Velero node-agent on every node" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n velero get ds node-agent -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context ${KUBECONTEXT} -n velero get ds node-agent -o jsonpath='{.status.desiredNumberScheduled}')\""
check "etcd snapshot CronJob scheduled" bash -c \
  "kubectl --context ${KUBECONTEXT} -n kube-system get cronjob etcd-snapshot >/dev/null"
check "an etcd snapshot exists in object storage" bash -c \
  "kubectl --context ${KUBECONTEXT} -n storage exec object-store-0 -- sh -c \"printf 'fs.ls /buckets/etcd\\n' | weed shell -master=localhost:9333 -filer=localhost:8888 2>/dev/null\" | grep -q 'etcd-.*\\.db'"

check "API audit log is mounted into Alloy" bash -c \
  "P=\$(kubectl --context ${KUBECONTEXT} -n observability get pods -l app.kubernetes.io/name=alloy -o json | jq -r '.items[]|select(.spec.nodeName|test(\"control-plane\"))|select(.status.phase==\"Running\")|.metadata.name' | head -1); \
   kubectl --context ${KUBECONTEXT} -n observability exec \$P -c alloy -- test -s /var/log/kubernetes/audit.log"
check "audit entries queryable in Loki" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/loki-gateway:80/proxy/loki/api/v1/label/job/values' | jq -e '.data|index(\"kubernetes-audit\")'"
check "Alertmanager has a receiver configured" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n observability get secret alertmanager-kps-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip 2>/dev/null | grep -c 'alert-sink')\" -ge 1"
check "alert sink is serving" bash -c \
  "kubectl --context ${KUBECONTEXT} -n observability get deploy alert-sink -o jsonpath='{.status.readyReplicas}' | grep -q 1"
check "priority classes defined" bash -c \
  "kubectl --context ${KUBECONTEXT} get priorityclass platform-critical platform-high tenant-default >/dev/null"
check "platform PodDisruptionBudgets present" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get pdb -A --no-headers | wc -l | tr -d ' ')\" -ge 4"

echo; log "resilience"
check "etcd quorum of 3" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n kube-system exec etcd-${CLUSTER_NAME}-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep -c started)\" = 3"
check "secrets encrypted at rest in etcd" bash -c \
  "kubectl --context ${KUBECONTEXT} -n default create secret generic smoke-enc --from-literal=k=SMOKECANARY --dry-run=client -o yaml | kubectl --context ${KUBECONTEXT} apply -f - >/dev/null; \
   ! kubectl --context ${KUBECONTEXT} -n kube-system exec etcd-${CLUSTER_NAME}-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/default/smoke-enc 2>/dev/null | grep -q SMOKECANARY"
kc -n default delete secret smoke-enc --ignore-not-found >/dev/null 2>&1 || true
check "Calico running on every node" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n calico-system get ds calico-node -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context ${KUBECONTEXT} -n calico-system get ds calico-node -o jsonpath='{.status.desiredNumberScheduled}')\""

echo; log "governance"
check "Kyverno webhook live" kc get clusterpolicy require-resource-requests
# Enforcement is proven by admission, not by reading the policy objects.
# Kyverno denies with "validation error", not "denied"/"blocked" -- matching on
# the wrong word previously made these look like they passed when they had not.
check "policies are enforcing, not auditing" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get clusterpolicy disallow-latest-tag -o jsonpath='{.spec.validationFailureAction}')\" = Enforce"
# Must satisfy PodSecurity restricted first, otherwise PSA rejects it before
# Kyverno is consulted and the check proves nothing about the image rule.
check "  :latest image is rejected" bash -c \
  "kubectl --context ${KUBECONTEXT} -n apps run smoke-latest --image=busybox:latest --restart=Never --dry-run=server \
     --overrides='{\"spec\":{\"containers\":[{\"name\":\"smoke-latest\",\"image\":\"busybox:latest\",\"command\":[\"true\"],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"}},\"securityContext\":{\"allowPrivilegeEscalation\":false,\"runAsNonRoot\":true,\"runAsUser\":1000,\"capabilities\":{\"drop\":[\"ALL\"]},\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}}]}}' \
     --command -- true 2>&1 | grep -q 'validation error'"
check "  missing resource requests rejected" bash -c \
  "kubectl --context ${KUBECONTEXT} create ns smoke-enf >/dev/null 2>&1; \
   kubectl --context ${KUBECONTEXT} -n smoke-enf run smoke-noreq --image=busybox:1.36 --restart=Never --dry-run=server --command -- true 2>&1 | grep -q 'validation error'"
check "  workloads rejected in the default namespace" bash -c \
  "kubectl --context ${KUBECONTEXT} -n default run smoke-def --image=busybox:1.36 --restart=Never --dry-run=server --command -- true 2>&1 | grep -q 'validation error'"
kc delete ns smoke-enf --wait=false >/dev/null 2>&1 || true
check "  platform namespaces stay exempt" bash -c \
  "kubectl --context ${KUBECONTEXT} -n observability run smoke-exempt --image=busybox:1.36 --restart=Never --dry-run=server --command -- true 2>&1 | grep -qv 'validation error'"

echo; log "secrets management"
check "Vault is unsealed" bash -c \
  "kubectl --context ${KUBECONTEXT} -n vault exec vault-0 -- vault status 2>/dev/null | grep -q 'Sealed  *false'"
check "no root token left on disk" bash -c "! test -s ${ROOT_DIR}/.secrets/vault-root-token"
# `vault auth list` needs a token, and root is deliberately revoked -- so this
# authenticates with the scoped installer AppRole, proving those credentials
# work as well as that the oidc backend exists.
check "OIDC auth enabled in Vault" bash -c \
  "T=\$(kubectl --context ${KUBECONTEXT} -n vault exec vault-0 -- vault write -field=token auth/approle/login \
        role_id=\$(cat ${ROOT_DIR}/.secrets/vault-installer-role-id) \
        secret_id=\$(cat ${ROOT_DIR}/.secrets/vault-installer-secret-id) 2>/dev/null); \
   kubectl --context ${KUBECONTEXT} -n vault exec vault-0 -- env VAULT_TOKEN=\$T vault auth list 2>/dev/null | grep -q '^oidc/'"
check "Vault OIDC issues a Keycloak auth URL" bash -c \
  "kubectl --context ${KUBECONTEXT} -n vault exec vault-0 -- vault write auth/oidc/oidc/auth_url role=default redirect_uri=https://vault.${BASE_DOMAIN}${URL_SUFFIX}/ui/vault/auth/oidc/oidc/callback 2>/dev/null | grep -q 'keycloak.${BASE_DOMAIN}'"
check "External Secrets store validated" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get clustersecretstore vault -o jsonpath='{.status.conditions[0].status}')\" = True"
check "a secret is actually synced out of Vault" bash -c \
  "test -n \"\$(kubectl --context ${KUBECONTEXT} -n external-secrets get secret vault-canary -o jsonpath='{.data.registry-username}' 2>/dev/null)\""
check "argocd-vault-plugin AppRole works" bash -c \
  "kubectl --context ${KUBECONTEXT} -n vault exec vault-0 -- vault write -field=token auth/approle/login role_id=\$(cat ${ROOT_DIR}/.secrets/avp-role-id) secret_id=\$(cat ${ROOT_DIR}/.secrets/avp-secret-id) >/dev/null 2>&1"
check "sealed-secrets controller running" bash -c \
  "kubectl --context ${KUBECONTEXT} -n kube-system get deploy sealed-secrets-controller -o jsonpath='{.status.readyReplicas}' | grep -q 1"

echo; log "gitops and console"
check "Argo CD server healthy"  http "https://argocd.${BASE_DOMAIN}${suffix}/healthz" '200'
check "Headlamp serving"        http "https://headlamp.${BASE_DOMAIN}${suffix}/" '200'

echo; log "local registry"
check "registry serves TLS from the platform CA" bash -c \
  "curl -sS --cacert '${CA}' --max-time 10 -o /dev/null -w '%{http_code}' https://localhost:${REGISTRY_HOST_PORT}/v2/ | grep -q 401"
check "registry rejects anonymous access" bash -c \
  "test \"\$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://localhost:${REGISTRY_HOST_PORT}/v2/)\" = 401"
check "registry accepts valid credentials" bash -c \
  "test \"\$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' -u \"\$(cat ${ROOT_DIR}/.secrets/registry-username):\$(cat ${ROOT_DIR}/.secrets/registry-password)\" https://localhost:${REGISTRY_HOST_PORT}/v2/)\" = 200"

kc -n apps delete pod smoke-priv --ignore-not-found >/dev/null 2>&1 || true

echo
if [[ ${fail} -eq 0 ]]; then ok "${pass} checks passed"; else die "${fail} of $((pass+fail)) checks failed"; fi
