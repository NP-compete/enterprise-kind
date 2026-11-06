#!/usr/bin/env bash
# Local OCI registry: localhost:${REGISTRY_HOST_PORT} from the host,
# ${REGISTRY_NAME}:5000 from inside the cluster. Backed by a named volume so
# images survive cluster rebuilds.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_registry() {
  if [[ "$("${CE}" inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" == "true" ]]; then
    ok "registry ${REGISTRY_NAME} already running"
    return
  fi
  "${CE}" rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  log "starting registry ${REGISTRY_NAME} on localhost:${REGISTRY_HOST_PORT}"
  local certs="${ROOT_DIR}/.secrets"
  [[ -s "${certs}/registry.crt" && -s "${certs}/registry.htpasswd" ]] \
    || die "registry TLS cert / htpasswd missing -- run scripts/pki.sh"
  "${CE}" run -d --restart=always \
    --name "${REGISTRY_NAME}" \
    -p "127.0.0.1:${REGISTRY_HOST_PORT}:5000" \
    -v "${REGISTRY_NAME}-data:/var/lib/registry" \
    -v "${certs}/registry.crt:/certs/tls.crt:ro" \
    -v "${certs}/registry.key:/certs/tls.key:ro" \
    -v "${certs}/registry.htpasswd:/auth/htpasswd:ro" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/tls.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/tls.key \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM="kind platform registry" \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    docker.io/library/registry:2 >/dev/null
  ok "registry started"
}

connect_registry() {
  # kind creates the network lazily; tolerate "already connected".
  "${CE}" network connect kind "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  ok "registry attached to the kind network"
}

configure_nodes() {
  local dir="/etc/containerd/certs.d/localhost:${REGISTRY_HOST_PORT}"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    "${CE}" exec "${node}" mkdir -p "${dir}"
    "${CE}" exec "${node}" mkdir -p /etc/containerd/certs.d/ca
    "${CE}" exec -i "${node}" sh -c "cat > /etc/containerd/certs.d/ca/platform-ca.crt" \
      < "${ROOT_DIR}/.secrets/platform-root-ca.crt"
    "${CE}" exec "${node}" sh -c "cat > ${dir}/hosts.toml <<'EOF'
[host.\"https://${REGISTRY_NAME}:5000\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/ca/platform-ca.crt\"
EOF"
  done
  ok "containerd mirror configured on all nodes"
}

advertise() {
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_HOST_PORT}"
    hostFromClusterNetwork: "${REGISTRY_NAME}:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  ok "registry advertised via kube-public/local-registry-hosting"
}

# The registry is a container on the kind network, not a pod, so the in-cluster
# Service for the UI needs its current address.
container_ip() {
  "${CE}" inspect "${REGISTRY_NAME}" \
    --format '{{range $k, $v := .NetworkSettings.Networks}}{{if eq $k "kind"}}{{$v.IPAddress}}{{end}}{{end}}'
}

case "${1:-all}" in
  ip)     container_ip ;;
  start)  start_registry ;;
  attach) connect_registry; configure_nodes; advertise ;;
  stop)   "${CE}" rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 && ok "registry removed" || true ;;
  all)    start_registry; connect_registry; configure_nodes; advertise ;;
  *)      die "usage: registry.sh [start|attach|stop|all]" ;;
esac
