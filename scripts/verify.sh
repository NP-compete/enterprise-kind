#!/usr/bin/env bash
# Verification suites. All require a running cluster.
#
# Usage: verify.sh <smoke|restore|failover> [args]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_smoke() {
# End-to-end verification: control plane, ingress+TLS, metrics, logs, traces,
# policy, registry. Exits non-zero on the first hard failure.

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
"${ROOT_DIR}/scripts/host-setup.sh" trust-ca export >/dev/null 2>&1 || true
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
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/query?query=up%7Bjob%3D%22kubelet%22%7D' | jq -e '[.data.result[] | select(.value[1]==\"1\")] | length >= 2'"
check "Prometheus has no down targets" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/targets?state=active' | jq -e '[.data.activeTargets[] | select(.health==\"down\")] | length == 0'"
check "Loki is ready" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/loki:3100/proxy/ready' | grep -qi ready"
check "Loki has ingested pod logs" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/loki-gateway:80/proxy/loki/api/v1/label/namespace/values' | jq -e '.data | length > 3'"
check "Grafana datasources reachable" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw '/api/v1/namespaces/observability/services/kps-grafana:80/proxy/api/health' | jq -e '.database == \"ok\"'"
check "Alloy running on every node" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n observability get ds alloy -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context ${KUBECONTEXT} -n observability get ds alloy -o jsonpath='{.status.desiredNumberScheduled}')\""

echo; log "durability"
check "object store serving S3" bash -c \
  "kubectl --context ${KUBECONTEXT} -n storage exec object-store-0 -- wget -qO- http://localhost:8333/status >/dev/null"
for b in loki velero postgres etcd; do
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
  "test \"\$(kubectl --context ${KUBECONTEXT} -n observability get deploy alert-sink -o jsonpath='{.status.readyReplicas}')\" -ge 1"
check "priority classes defined" bash -c \
  "kubectl --context ${KUBECONTEXT} get priorityclass platform-critical platform-high tenant-default >/dev/null"
check "platform PodDisruptionBudgets present" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get pdb -A --no-headers | wc -l | tr -d ' ')\" -ge 4"

echo; log "resilience"
# One etcd member. Asserted rather than skipped so that a change back to a
# multi-member control plane is a visible, deliberate edit here too.
check "etcd has 1 started member (no quorum, by design)" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n kube-system exec etcd-${CLUSTER_NAME}-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep -c started)\" = 1"
check "secrets encrypted at rest in etcd" bash -c \
  "kubectl --context ${KUBECONTEXT} -n default create secret generic smoke-enc --from-literal=k=SMOKECANARY --dry-run=client -o yaml | kubectl --context ${KUBECONTEXT} apply -f - >/dev/null; \
   ! kubectl --context ${KUBECONTEXT} -n kube-system exec etcd-${CLUSTER_NAME}-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/default/smoke-enc 2>/dev/null | grep -q SMOKECANARY"
kc -n default delete secret smoke-enc --ignore-not-found >/dev/null 2>&1 || true
check "Calico running on every node" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n calico-system get ds calico-node -o jsonpath='{.status.numberReady}')\" = \"\$(kubectl --context ${KUBECONTEXT} -n calico-system get ds calico-node -o jsonpath='{.status.desiredNumberScheduled}')\""

echo; log "topology"
K="kubectl --context ${KUBECONTEXT}"
# This cluster is deliberately 1 control plane + 1 worker and single-replica
# throughout. These checks assert that shape rather than redundancy: the
# point is to catch something silently scaling back up and blowing the
# memory budget, which is the failure this configuration actually has.
check "exactly 1 control plane and 1 worker" bash -c \
  "test \"\$(${K} get nodes --no-headers | wc -l | tr -d ' ')\" = 2"
# coredns is excluded: it is a Kubernetes default, not a platform component,
# and two replicas of it cost ~40 MiB while making DNS survive a pod restart.
check "no platform workload runs more than one replica" bash -c "
  over=\$(${K} get deploy,statefulset -A -o json | jq -r '
    [.items[] | select((.spec.replicas // 1) > 1)
      | select(.metadata.name != \"coredns\")
      | .metadata.namespace + \"/\" + .metadata.name] | .[]')
  test -z \"\$over\" || { echo \"scaled up: \$over\"; false; }"

check "Postgres cluster healthy" bash -c \
  "test \"\$(${K} -n identity get cluster platform-pg -o jsonpath='{.status.readyInstances}')\" = \"${PG_INSTANCES}\""
check "Postgres has a primary" bash -c \
  "test \"\$(${K} -n identity get pods -l cnpg.io/cluster=platform-pg,cnpg.io/instanceRole=primary --no-headers | wc -l | tr -d ' ')\" = 1"
# grafana.ini lives in a ConfigMap; only the admin credentials are in the Secret.
check "Grafana state is in Postgres, not SQLite" bash -c \
  "${K} -n observability get cm kps-grafana -o jsonpath='{.data.grafana\.ini}' | grep -q 'type = postgres'"

# Dropped on purpose. If one of these reappears the footprint has regressed.
for ns in metallb-system trivy-system keda; do
  check "namespace ${ns} is absent" bash -c "! ${K} get namespace ${ns} >/dev/null 2>&1"
done
check "Tempo is not installed" bash -c "! ${K} -n observability get statefulset tempo >/dev/null 2>&1"
check "Argo CD uses plain redis, not redis-ha" bash -c \
  "! ${K} -n argocd get statefulset argocd-redis-ha-server >/dev/null 2>&1"

# Budgets must be satisfiable. At one replica a minAvailable:1 budget never
# is, and the node becomes permanently undrainable -- so assert the shape.
check "no PodDisruptionBudget uses minAvailable" bash -c \
  "test \"\$(${K} get pdb -A -o json | jq '[.items[] | select(.spec.minAvailable != null)] | length')\" = 0"
check "every PodDisruptionBudget is satisfiable" bash -c \
  "test \"\$(${K} get pdb -A -o json | jq '[.items[] | select(.status.currentHealthy < .status.desiredHealthy)] | length')\" = 0"

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
}

cmd_restore() {
# Prove the backups can actually restore, rather than assuming.
#
#   make restore-drill
#
# Creates a throwaway namespace with a canary ConfigMap and a PVC, backs it up
# with Velero, destroys it, restores it, and checks the data came back. Touches
# nothing outside the drill namespace.
#
# An untested backup is not a backup. Run this after changing anything about
# storage, Velero, or the object store.

NS=restore-drill
BACKUP="drill-$(date -u +%Y%m%d%H%M%S)"
CANARY="the-quick-brown-fox-$(date -u +%s)"

cleanup() {
  kc delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "1/6  creating the drill namespace with a canary"
kc delete namespace "${NS}" --wait=true >/dev/null 2>&1 || true
kc create namespace "${NS}" >/dev/null
kc label namespace "${NS}" platform.kind.local/component=drill >/dev/null
kc -n "${NS}" create configmap canary --from-literal=value="${CANARY}" >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: canary-data
  namespace: ${NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources: { requests: { storage: 64Mi } }
EOF
ok "canary value: ${CANARY}"

log "2/6  backing up the namespace"
kc apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP}
  namespace: velero
spec:
  includedNamespaces: ["${NS}"]
  ttl: 1h
  snapshotVolumes: false
  storageLocation: default
EOF
for _ in $(seq 1 60); do
  phase="$(kc -n velero get backup "${BACKUP}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${phase}" in Completed|PartiallyFailed|Failed|FailedValidation) break ;; esac
  sleep 5
done
[[ "${phase}" == "Completed" ]] || die "backup did not complete (phase=${phase:-unknown})"
ok "backup ${BACKUP} Completed"

log "3/6  destroying the namespace"
kc delete namespace "${NS}" --wait=true >/dev/null
kc get namespace "${NS}" >/dev/null 2>&1 && die "namespace still present after delete"
ok "namespace gone"

log "4/6  restoring from the backup"
kc apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${BACKUP}-restore
  namespace: velero
spec:
  backupName: ${BACKUP}
  existingResourcePolicy: update
EOF
for _ in $(seq 1 60); do
  rphase="$(kc -n velero get restore "${BACKUP}-restore" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${rphase}" in Completed|PartiallyFailed|Failed) break ;; esac
  sleep 5
done
ok "restore phase: ${rphase:-unknown}"

log "5/6  checking the canary survived"
for _ in $(seq 1 24); do
  got="$(kc -n "${NS}" get configmap canary -o jsonpath='{.data.value}' 2>/dev/null || true)"
  [[ -n "${got}" ]] && break
  sleep 5
done
[[ "${got}" == "${CANARY}" ]] \
  || die "canary mismatch: expected '${CANARY}', got '${got:-<nothing>}'"
ok "canary restored intact"

log "6/6  checking the PVC came back"
pvc="$(kc -n "${NS}" get pvc canary-data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ -n "${pvc}" ]] && ok "PVC restored (phase=${pvc})" || warn "PVC did not come back"

echo
ok "RESTORE DRILL PASSED -- backup ${BACKUP} restored a destroyed namespace"
echo "   etcd snapshots are a separate path: see docs/disaster-recovery.md"
}

cmd_failover() {
# Prove the HA claim the way restore-drill proves the backup claim: by
# actually taking a node away and checking what survives.
#
# Replica counts and anti-affinity rules are intent. This is the measurement.
# It cordons and drains a worker, waits, and then asks whether every console
# still answers, whether Postgres still has a primary, whether Vault still
# has Raft quorum, and whether anything ended up with zero ready replicas.
# Then it puts the node back.
#
#   make failover-drill             drain worker 2 (not the ingress node)
#   NODE=kindprod-worker3 make failover-drill
#
# Worker 1 is the default exclusion because kind publishes the host's 80/443
# from that container: draining it costs browser access to the consoles from
# the Mac regardless of how healthy the cluster is. Pass NODE= to insist.

cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist"

# With one worker, draining it tests shutdown, not failover. Refuse rather
# than report a meaningless failure. Scale cluster/kind-config.yaml and the
# replica counts in platform/values/ back up and this measures again.
WORKERS="$(kc get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${WORKERS}" -lt 2 ]]; then
  warn "this cluster has ${WORKERS} worker node; a failover drill needs at least 2"
  warn "nothing to measure -- the platform is deliberately single-replica here"
  warn "see 'Known limits' in README.md"
  exit 0
fi

NODE="${NODE:-${CLUSTER_NAME}-worker2}"
kc get node "${NODE}" >/dev/null 2>&1 || die "no such node: ${NODE}"

pass=0; fail=0
check() { local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  \033[1;32m✓\033[0m %s\n' "${name}"; pass=$((pass+1))
  else printf '  \033[1;31m✗\033[0m %s\n' "${name}"; fail=$((fail+1)); fi
}
suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"
http() { curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "$1" | grep -qE "$2"; }

restore_node() {
  log "uncordoning ${NODE}"
  kc uncordon "${NODE}" >/dev/null 2>&1 || true
}
# Put the node back even if the drill is interrupted; leaving a cordoned node
# behind would quietly degrade every later run.
trap restore_node EXIT INT TERM

echo
log "baseline: what is running on ${NODE}"
kc get pods -A --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null \
  | awk '{print "   " $1 "/" $2}' | head -40
BEFORE="$(kc get pods -A --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
ok "${BEFORE} pods on ${NODE}"

echo
log "draining ${NODE}"
# --delete-emptydir-data because several platform components keep caches in
# emptyDir; --ignore-daemonsets because a DaemonSet pod is supposed to stay.
# No --force: a pod with no controller SHOULD block this, since nothing would
# recreate it. --disable-eviction is deliberately NOT set, so the drain has to
# pass through the PodDisruptionBudgets -- which is itself part of the test.
if kc drain "${NODE}" \
     --ignore-daemonsets --delete-emptydir-data \
     --timeout=300s >/dev/null 2>&1; then
  ok "drained cleanly, respecting every PodDisruptionBudget"
else
  warn "drain did not finish within 300s -- continuing with the node cordoned"
  warn "a PDB that cannot be satisfied will do this; check: kubectl get pdb -A"
fi

log "letting the rescheduled pods settle"
sleep 45

echo
log "with ${NODE} out of service"

check "every node except ${NODE} is Ready" bash -c \
  "! kubectl --context ${KUBECONTEXT} get nodes --no-headers | grep -v '${NODE}' | grep -v ' Ready '"

# The real question: did anything lose all of its replicas?
check "no Deployment is at zero ready replicas" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get deploy -A -o json \
     | jq '[.items[] | select(.spec.replicas > 0) | select((.status.readyReplicas // 0) == 0)] | length')\" = 0"
check "no StatefulSet is at zero ready replicas" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get statefulset -A -o json \
     | jq '[.items[] | select(.spec.replicas > 0) | select((.status.readyReplicas // 0) == 0)] | length')\" = 0"

for host in grafana argocd headlamp keycloak home; do
  check "https://${host}.${BASE_DOMAIN} still answers" \
    http "https://${host}.${BASE_DOMAIN}${suffix}/" '200|301|302|307|401|403'
done

check "Postgres still has a primary" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} -n identity get pods \
     -l cnpg.io/cluster=platform-pg,cnpg.io/instanceRole=primary --no-headers 2>/dev/null \
     | wc -l | tr -d ' ')\" = 1"
check "Postgres accepts a write" bash -c \
  "P=\$(kubectl --context ${KUBECONTEXT} -n identity get pod \
       -l cnpg.io/cluster=platform-pg,cnpg.io/instanceRole=primary \
       -o jsonpath='{.items[0].metadata.name}'); \
   kubectl --context ${KUBECONTEXT} -n identity exec \$P -c postgres -- \
     psql -v ON_ERROR_STOP=1 -q -c 'CREATE TABLE IF NOT EXISTS failover_drill(t timestamptz); INSERT INTO failover_drill VALUES (now());'"

check "Vault still has Raft quorum" bash -c \
  "n=0; for p in vault-0 vault-1 vault-2; do
     kubectl --context ${KUBECONTEXT} -n vault exec \$p -- vault status 2>/dev/null \
       | grep -q 'Sealed  *false' && n=\$((n+1));
   done; test \$n -ge 2"

check "Kyverno still admits and rejects" bash -c \
  "kubectl --context ${KUBECONTEXT} -n default run drill-def --image=busybox:1.36 \
     --restart=Never --dry-run=server --command -- true 2>&1 | grep -q 'validation error'"

check "Prometheus still scraping" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw \
     '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/-/healthy' | grep -qi healthy"

check "Loki write path still ready" bash -c \
  "kubectl --context ${KUBECONTEXT} get --raw \
     '/api/v1/namespaces/observability/services/loki-write:3100/proxy/ready' | grep -qi ready"

echo
restore_node
trap - EXIT INT TERM

log "waiting for the cluster to return to full strength"
for _ in $(seq 1 60); do
  pending="$(kc get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${pending}" == "0" ]] && break
  sleep 10
done
check "nothing left Pending" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')\" = 0"
check "workloads rebalanced back onto ${NODE}" bash -c \
  "test \"\$(kubectl --context ${KUBECONTEXT} get pods -A --field-selector spec.nodeName=${NODE} --no-headers 2>/dev/null | wc -l | tr -d ' ')\" -gt 0"

echo
if [[ ${fail} -eq 0 ]]; then
  ok "${pass} checks passed -- the platform survived losing ${NODE}"
else
  die "${fail} of $((pass+fail)) checks failed while ${NODE} was down"
fi
}

_usage() {
  echo "usage: $(basename "$0") <smoke|restore|failover> [args]" >&2
  exit 2
}
[[ $# -ge 1 ]] || _usage
_sub="$1"; shift
case "${_sub}" in
  smoke) cmd_smoke "$@" ;;
  restore) cmd_restore "$@" ;;
  failover) cmd_failover "$@" ;;
  *) _usage ;;
esac
