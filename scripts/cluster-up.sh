#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"${ROOT_DIR}/scripts/preflight.sh"
# The CA, the etcd encryption key and the OIDC authentication config must all
# exist before kubeadm runs -- the API server mounts them at startup.
"${ROOT_DIR}/scripts/pki.sh"
"${ROOT_DIR}/scripts/render-authn.sh"
"${ROOT_DIR}/scripts/registry.sh" start

if cluster_exists; then
  ok "cluster '${CLUSTER_NAME}' already exists"
else
  rendered="${BUILD_DIR}/kind-config.yaml"
  envsubst '${CLUSTER_NAME} ${NODE_IMAGE} ${API_SERVER_PORT} ${HTTP_PORT} ${HTTPS_PORT} ${POLICY_DIR}' \
    < "${ROOT_DIR}/cluster/kind-config.yaml" > "${rendered}"
  log "creating kind cluster '${CLUSTER_NAME}' (3 control-plane + 3 workers, no CNI yet)"
  # --wait is pointless here: without a CNI no node reaches Ready.
  kind create cluster --config "${rendered}"
fi

kubectl config use-context "${KUBECONTEXT}" >/dev/null

# ---------------------------------------------------------------- CNI
# Calico has to go in before anything else can schedule.
if ! kc -n calico-system get daemonset calico-node >/dev/null 2>&1; then
  log "installing Calico (CNI + enforced NetworkPolicy)"
fi
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo update projectcalico >/dev/null 2>&1 || true

# A CNI legitimately needs host namespaces and hostPath volumes, which the
# cluster-wide PodSecurity default (baseline) forbids. Create its namespaces up
# front as privileged -- namespace labels override the default, so this needs no
# API server restart.
for ns in tigera-operator calico-system calico-apiserver; do
  kc create namespace "${ns}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc label namespace "${ns}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/warn=privileged \
    pod-security.kubernetes.io/audit=privileged \
    platform.kind.local/component=cni --overwrite >/dev/null
done
ok "CNI namespaces created with privileged PodSecurity"

# The tigera-operator chart assumes its CRDs already exist (Installation,
# Goldmane, Whisker); helm will not create them itself. Server-side apply
# because the Calico CRDs exceed the annotation size limit of client-side apply.
kc apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CHART_CALICO}/manifests/operator-crds.yaml" >/dev/null
ok "Calico operator CRDs applied"

helm upgrade --install calico projectcalico/tigera-operator \
  --version "${CHART_CALICO}" \
  --namespace tigera-operator --create-namespace \
  --kube-context "${KUBECONTEXT}" \
  -f "${ROOT_DIR}/platform/values/calico.yaml" \
  --timeout 10m >/dev/null
ok "Calico operator installed"

log "waiting for Calico to program the dataplane"
for _ in $(seq 1 60); do
  ready=$(kc -n calico-system get daemonset calico-node -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  want=$(kc -n calico-system get daemonset calico-node -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  [[ "${want}" != "0" && "${ready}" == "${want}" ]] && break
  sleep 10
done
ok "Calico ready on ${ready:-0}/${want:-0} nodes"

log "waiting for all nodes to become Ready"
kc wait --for=condition=Ready nodes --all --timeout=10m >/dev/null || warn "some nodes are still not Ready"

"${ROOT_DIR}/scripts/registry.sh" attach

kc label namespace default \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite >/dev/null

kc get nodes -o wide
ok "cluster '${CLUSTER_NAME}' ready (context: ${KUBECONTEXT})"
