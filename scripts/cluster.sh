#!/usr/bin/env bash
# Lifecycle of the kind cluster itself and the host-side pieces it needs.
#
# Usage: cluster.sh <preflight|pki|authn|registry|dns|up|down|node-image> [args]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_preflight() {
log "preflight"
for t in kind kubectl helm "${CE}" envsubst; do need "$t"; done

"${CE}" info >/dev/null 2>&1 || die "${CE} is not responding. For podman: podman machine start"

if [[ "${CE}" == "podman" ]]; then
  cpus=$(podman machine inspect --format '{{.Resources.CPUs}}' 2>/dev/null | head -1 || echo 0)
  mem=$(podman machine inspect --format '{{.Resources.Memory}}'  2>/dev/null | head -1 || echo 0)
  # Measured: 9.7 GiB steady state on a 1+1 node cluster. 12 GiB leaves room
  # for workloads and the page cache kubelet and containerd want.
  [[ "${cpus:-0}" -ge 4     ]] || warn "podman machine has ${cpus} CPUs; >=4 recommended"
  [[ "${mem:-0}"  -ge 12288 ]] || warn "podman machine has ${mem}MiB RAM; >=12288 recommended"
  ok "podman machine: ${cpus} cpu / ${mem} MiB"

  # Rootless podman cannot publish ports < 1024 unless the VM kernel allows it.
  # The sysctl lives inside the podman VM, not on macOS, so this is safe to set.
  lowest=$(printf '%s\n' "${HTTP_PORT}" "${HTTPS_PORT}" | sort -n | head -1)
  if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" && "${lowest}" -lt 1024 ]]; then
    current=$(podman machine ssh 'cat /proc/sys/net/ipv4/ip_unprivileged_port_start' 2>/dev/null || echo 1024)
    if [[ "${current}" -gt "${lowest}" ]]; then
      log "allowing unprivileged ports >= ${lowest} inside the podman VM"
      podman machine ssh "sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=${lowest} > /etc/sysctl.d/99-kind-ports.conf && sysctl -w net.ipv4.ip_unprivileged_port_start=${lowest}'" >/dev/null \
        || die "could not lower ip_unprivileged_port_start; set HTTP_PORT/HTTPS_PORT to >=1024 in config.env"
    fi
    ok "podman VM allows binding port ${lowest}"
  fi

  # Container churn exhausts the per-user kernel keyring and new containers then
  # fail with "unable to join session keyring: disk quota exceeded".
  keys=$(podman machine ssh 'cat /proc/sys/kernel/keys/maxkeys' 2>/dev/null || echo 0)
  if [[ "${keys:-0}" -lt 100000 ]]; then
    log "raising kernel keyring limits inside the podman VM"
    podman machine ssh "sudo sh -c 'printf \"kernel.keys.maxkeys=2000000\\nkernel.keys.maxbytes=50000000\\nkernel.keys.root_maxkeys=2000000\\nkernel.keys.root_maxbytes=50000000\\n\" > /etc/sysctl.d/99-kind-keyring.conf && sysctl -p /etc/sysctl.d/99-kind-keyring.conf'" >/dev/null \
      || warn "could not raise kernel.keys.maxkeys; containers may fail with 'disk quota exceeded'"
  fi
  ok "podman VM keyring limit: $(podman machine ssh 'cat /proc/sys/kernel/keys/maxkeys' 2>/dev/null)"

  # Rootless podman delegates only "memory pids cpu io" by default. Without
  # cpuset the kubelet cannot enforce node allocatable and every node logs
  # FailedNodeAllocatableEnforcement ("cpuset.cpus: no such file") forever.
  if ! podman machine ssh 'cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers' 2>/dev/null | grep -qw cpuset; then
    warn "cpuset is not delegated to rootless podman; enabling it"
    warn "this restarts the user systemd slice and will STOP running containers"
    podman machine ssh "sudo sh -c 'mkdir -p /etc/systemd/system/user@.service.d && printf \"[Service]\\nDelegate=memory pids cpu io cpuset\\n\" > /etc/systemd/system/user@.service.d/delegate.conf && systemctl daemon-reload'" >/dev/null 2>&1 \
      || warn "could not write the delegation config"
    warn "restart the podman machine to apply: podman machine stop && podman machine start"
  else
    ok "podman VM delegates cpuset (node allocatable enforcement works)"
  fi
fi

# Our own cluster legitimately holds these ports; only look for foreign ones.
if cluster_exists; then
  ok "cluster '${CLUSTER_NAME}' already exists -- skipping port conflict checks"
  exit 0
fi

for p in "${HTTP_PORT}" "${HTTPS_PORT}" "${API_SERVER_PORT}" "${REGISTRY_HOST_PORT}"; do
  if lsof -nP -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1; then
    if "${CE}" ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${p}->"; then
      warn "port ${p} is held by an existing ${CE} container (probably this stack)"
    else
      die "port ${p} is already in use by another process"
    fi
  fi
done

ok "preflight passed"
}

cmd_pki() {
# Generate the platform's root CA and the etcd encryption key *before* the
# cluster exists.
#
# Both are needed by the API server at kubeadm time: the CA so it can validate
# Keycloak's TLS when the OIDC authenticator initialises, and the encryption key
# for secrets-at-rest. Generating them here (rather than letting cert-manager
# mint the CA afterwards) is what lets both be declared in kind-config.yaml
# instead of patched into a running control plane.
#
# Everything lands in .secrets/ (gitignored) and is reused on later runs, so a
# rebuild keeps the same CA and your browser keeps trusting it.

SECRETS_DIR="${ROOT_DIR}/.secrets"
POLICIES="${ROOT_DIR}/cluster/policies"
mkdir -p "${SECRETS_DIR}" "${POLICIES}"
chmod 700 "${SECRETS_DIR}"

CA_KEY="${SECRETS_DIR}/platform-root-ca.key"
CA_CRT="${SECRETS_DIR}/platform-root-ca.crt"

if [[ -s "${CA_KEY}" && -s "${CA_CRT}" ]]; then
  # Refuse to silently keep an expired CA.
  if openssl x509 -in "${CA_CRT}" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "platform CA present (expires $(openssl x509 -in "${CA_CRT}" -noout -enddate | cut -d= -f2))"
  else
    warn "platform CA expires within 30 days -- regenerating (re-run 'make trust-ca')"
    rm -f "${CA_KEY}" "${CA_CRT}"
  fi
fi

if [[ ! -s "${CA_KEY}" ]]; then
  log "generating the platform root CA (10 years)"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${CA_KEY}" -out "${CA_CRT}" \
    -subj "/O=kind platform/CN=kind-platform-root-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    >/dev/null 2>&1 || die "openssl failed to generate the CA"
  chmod 600 "${CA_KEY}"
  chmod 644 "${CA_CRT}"
  ok "root CA written to ${CA_CRT}"
fi

# The API server reads this from the mounted policies directory.
cp "${CA_CRT}" "${POLICIES}/platform-ca.crt"

# --- secrets encryption at rest -------------------------------------------
ENC_KEY_FILE="${SECRETS_DIR}/etcd-encryption.key"
if [[ ! -s "${ENC_KEY_FILE}" ]]; then
  log "generating the etcd encryption key"
  head -c 32 /dev/urandom | base64 > "${ENC_KEY_FILE}"
  chmod 600 "${ENC_KEY_FILE}"
fi

cat > "${POLICIES}/encryption-config.yaml" <<EOF
---
# Secrets are encrypted before they reach etcd. Losing
# .secrets/etcd-encryption.key makes existing Secrets unreadable, so the key is
# generated once and reused across rebuilds.
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $(cat "${ENC_KEY_FILE}")
      # Identity last so Secrets written before encryption was enabled remain
      # readable; every new write uses aescbc.
      - identity: {}
EOF
chmod 600 "${POLICIES}/encryption-config.yaml"
ok "etcd encryption config written"

# --- registry server certificate -------------------------------------------
# The local registry runs as a container outside the cluster, so cert-manager
# cannot issue for it. Sign a leaf from the same platform CA instead, covering
# every name it is reached by: the container name (from inside the kind
# network) and localhost (from the host).
REG_KEY="${SECRETS_DIR}/registry.key"
REG_CRT="${SECRETS_DIR}/registry.crt"
if [[ ! -s "${REG_CRT}" ]] || ! openssl x509 -in "${REG_CRT}" -noout -checkend 2592000 >/dev/null 2>&1; then
  log "issuing the registry TLS certificate from the platform CA"
  cat > "${BUILD_DIR}/registry-san.cnf" <<CNF
[req]
distinguished_name = dn
[dn]
[ext]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${REGISTRY_NAME},DNS:localhost,DNS:registry.${BASE_DOMAIN},DNS:registry-backend.registry.svc.cluster.local,DNS:registry-backend.registry.svc,IP:127.0.0.1
CNF
  openssl req -newkey rsa:2048 -nodes -keyout "${REG_KEY}" \
    -subj "/O=kind platform/CN=${REGISTRY_NAME}" -out "${BUILD_DIR}/registry.csr" >/dev/null 2>&1
  openssl x509 -req -in "${BUILD_DIR}/registry.csr" \
    -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${REG_CRT}" -days 825 -sha256 \
    -extfile "${BUILD_DIR}/registry-san.cnf" -extensions ext >/dev/null 2>&1 \
    || die "could not issue the registry certificate"
  chmod 600 "${REG_KEY}"; chmod 644 "${REG_CRT}"
  ok "registry certificate issued"
fi

# --- registry credentials ---------------------------------------------------
REG_USER_FILE="${SECRETS_DIR}/registry-username"
REG_PASS_FILE="${SECRETS_DIR}/registry-password"
[[ -s "${REG_USER_FILE}" ]] || printf 'platform' > "${REG_USER_FILE}"
if [[ ! -s "${REG_PASS_FILE}" ]]; then
  rand_alnum 32 > "${REG_PASS_FILE}"
  chmod 600 "${REG_PASS_FILE}"
fi
HTPASSWD_FILE="${SECRETS_DIR}/registry.htpasswd"
if [[ ! -s "${HTPASSWD_FILE}" ]]; then
  log "generating registry credentials"
  # bcrypt is what distribution expects; the httpd image is the simplest way
  # to produce it without adding a host dependency. Pull first: if the image is
  # absent, pull progress races the stdout redirect and the file comes out empty.
  "${CONTAINER_ENGINE}" pull -q docker.io/library/httpd:2.4-alpine >/dev/null 2>&1 || true
  "${CONTAINER_ENGINE}" run --rm docker.io/library/httpd:2.4-alpine \
    htpasswd -Bbn "$(cat "${REG_USER_FILE}")" "$(cat "${REG_PASS_FILE}")" \
    > "${HTPASSWD_FILE}" 2>/dev/null || die "could not generate the htpasswd file"
  [[ -s "${HTPASSWD_FILE}" ]] || die "htpasswd file came out empty"
  chmod 600 "${HTPASSWD_FILE}"
  ok "registry credentials generated"
fi
}

cmd_authn() {
# Render the API server's OIDC authentication config from the pre-generated CA.
#
# Split out of apiserver-oidc.sh because it has to run before `kind create`:
# the API server mounts this file at kubeadm time. It is safe to point at a
# Keycloak that does not exist yet -- the API server starts anyway and retries
# the OIDC discovery in the background until Keycloak answers.

CA_CRT="${ROOT_DIR}/.secrets/platform-root-ca.crt"
[[ -s "${CA_CRT}" ]] || die "no platform CA at ${CA_CRT} -- run scripts/cluster.sh pki first"

PLATFORM_CA_PEM_INDENTED8="$(sed 's/^/        /' "${CA_CRT}")"
export PLATFORM_CA_PEM_INDENTED8
export AUTHN_API_VERSION="${AUTHN_API_VERSION:-v1}"

envsubst '${AUTHN_API_VERSION} ${BASE_DOMAIN} ${URL_SUFFIX} ${PLATFORM_CA_PEM_INDENTED8}' \
  < "${ROOT_DIR}/cluster/policies/authentication-config.yaml.tmpl" \
  > "${ROOT_DIR}/cluster/policies/authentication-config.yaml"

ok "authentication-config.yaml rendered (issuer: https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}/realms/platform)"
}

cmd_registry() {
# Local OCI registry: localhost:${REGISTRY_HOST_PORT} from the host,
# ${REGISTRY_NAME}:5000 from inside the cluster. Backed by a named volume so
# images survive cluster rebuilds.

start_registry() {
  if [[ "$("${CE}" inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" == "true" ]]; then
    ok "registry ${REGISTRY_NAME} already running"
    return
  fi
  "${CE}" rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  log "starting registry ${REGISTRY_NAME} on localhost:${REGISTRY_HOST_PORT}"
  local certs="${ROOT_DIR}/.secrets"
  [[ -s "${certs}/registry.crt" && -s "${certs}/registry.htpasswd" ]] \
    || die "registry TLS cert / htpasswd missing -- run scripts/cluster.sh pki"
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
  # Two client-facing names for the same registry:
  #   localhost:<port>      what you push to from the host
  #   <name>:5000           what pods reference and Kyverno verifies
  # Both need a hosts.toml so containerd uses TLS and trusts the platform CA.
  local dir="/etc/containerd/certs.d/localhost:${REGISTRY_HOST_PORT}"
  local dir_internal="/etc/containerd/certs.d/${REGISTRY_NAME}:5000"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    "${CE}" exec "${node}" mkdir -p "${dir}"
    "${CE}" exec "${node}" mkdir -p /etc/containerd/certs.d/ca
    "${CE}" exec -i "${node}" sh -c "cat > /etc/containerd/certs.d/ca/platform-ca.crt" \
      < "${ROOT_DIR}/.secrets/platform-root-ca.crt"
    "${CE}" exec "${node}" mkdir -p "${dir_internal}"
    for d in "${dir}" "${dir_internal}"; do
      "${CE}" exec "${node}" sh -c "cat > ${d}/hosts.toml <<'EOF'
[host.\"https://${REGISTRY_NAME}:5000\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/ca/platform-ca.crt\"
EOF"
    done
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
}

cmd_dns() {
# Make the platform's public hostnames resolvable from inside the cluster.
#
# Grafana, Argo CD, Headlamp and oauth2-proxy all perform server-side OIDC calls
# to https://keycloak.${BASE_DOMAIN}. That name only exists in the browser unless
# CoreDNS knows about it, so point *.${BASE_DOMAIN} at the ingress controller.

EXPECTED="name regex (.*)\\.${BASE_DOMAIN//./\\.}\\.?\$ ingress-nginx-controller"

current="$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
if grep -qF "${EXPECTED}" <<<"${current}"; then
  ok "CoreDNS already resolves *.${BASE_DOMAIN} to the ingress controller"
  exit 0
fi

log "teaching CoreDNS about *.${BASE_DOMAIN}"
updated="$(BASE_DOMAIN="${BASE_DOMAIN}" python3 -I "${ROOT_DIR}/scripts/coredns_rewrite.py" <<<"${current}")"

kc -n kube-system create configmap coredns --from-literal=Corefile="${updated}" \
  --dry-run=client -o yaml | kc -n kube-system patch configmap coredns --patch-file=/dev/stdin >/dev/null

kc -n kube-system rollout restart deployment/coredns >/dev/null
kc -n kube-system rollout status deployment/coredns --timeout=3m >/dev/null
ok "CoreDNS resolves *.${BASE_DOMAIN} to ingress-nginx"
}

cmd_up() {
  _on_fail_up() {
    local rc=$?
    [[ ${rc} -eq 0 ]] && return 0
    hint "cluster creation failed. Most causes are the container engine or a" \
         "half-created cluster from a previous attempt:" \
         "  make doctor" \
         "  make clean && make up"
    return ${rc}
  }
  trap _on_fail_up EXIT

"${ROOT_DIR}/scripts/cluster.sh" preflight
# The CA, the etcd encryption key and the OIDC authentication config must all
# exist before kubeadm runs -- the API server mounts them at startup.
"${ROOT_DIR}/scripts/cluster.sh" pki
"${ROOT_DIR}/scripts/cluster.sh" authn
"${ROOT_DIR}/scripts/cluster.sh" registry start

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

"${ROOT_DIR}/scripts/cluster.sh" registry attach

kc label namespace default \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite >/dev/null

kc get nodes -o wide
ok "cluster '${CLUSTER_NAME}' ready (context: ${KUBECONTEXT})"
}

cmd_down() {
if cluster_exists; then
  log "deleting cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "cluster deleted"
else
  warn "cluster '${CLUSTER_NAME}' not found"
fi

if [[ "${1:-}" == "--all" ]]; then
  "${ROOT_DIR}/scripts/cluster.sh" registry stop
  "${CE}" volume rm "${REGISTRY_NAME}-data" >/dev/null 2>&1 && ok "registry volume removed" || true
  rm -rf "${BUILD_DIR}"
  ok "build artifacts removed (.secrets kept)"
else
  warn "registry '${REGISTRY_NAME}' left running -- 'make clean' removes it too"
fi
}

cmd_node_image() {
  # Bakes a kind node image with every platform image already in its
  # containerd store. A cold build otherwise pulls ~29 images into each
  # node; preloading moves that cost to a one-off build that is cached in
  # a registry and shared.
  #
  #   node-image list    regenerate cluster/node-images.txt from a live cluster
  #   node-image build   bake it locally
  #   node-image push    push to GHCR
  #   node-image tag     print the tag that build/push would use
  local sub="${1:-build}"; shift || true

  local LIST="${ROOT_DIR}/cluster/node-images.txt"
  local BASE="${NODE_IMAGE_BASE:-${NODE_IMAGE%%@*}}"
  local REPO="${NODE_IMAGE_REPO:-ghcr.io/np-compete/enterprise-kind/node}"

  _images() { grep -vE '^\s*#|^\s*$' "${LIST}"; }
  # Tag ties the image to both the Kubernetes version and the exact image
  # set, so a stale bake can never silently be reused after a chart bump.
  _tag() {
    local k8s hash
    k8s="$(sed 's/.*node://; s/@.*//' <<<"${BASE}")"
    hash="$(_images | shasum -a 256 | cut -c1-12)"
    printf '%s:%s-%s' "${REPO}" "${k8s}" "${hash}"
  }

  case "${sub}" in
    list)
      cluster_exists || die "needs a running cluster to read images from"
      { echo "# Images preloaded into the baked node image. Regenerate against a"
        echo "# running cluster with:  ./scripts/cluster.sh node-image list"
        echo "# Keep sorted; the tag of the baked image is a hash of this file."
        kc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
          | sort -u | grep -v '^$'
      } > "${LIST}"
      ok "wrote $(grep -cvE '^\s*#|^\s*$' "${LIST}") images to ${LIST}"
      ;;

    tag) printf '%s\n' "$(_tag)" ;;

    build)
      need "${CE}"
      [[ -s "${LIST}" ]] || die "no image list at ${LIST} -- run: cluster.sh node-image list"
      local tag bake="kindnode-bake" n=0 total
      tag="$(_tag)"
      total="$(_images | wc -l | tr -d ' ')"
      log "baking ${tag} from ${BASE} (${total} images)"

      "${CE}" rm -f "${bake}" >/dev/null 2>&1 || true
      # systemd inside, exactly as kind runs its nodes, so containerd comes
      # up on its own and ctr can import into the real k8s.io namespace.
      "${CE}" run -d --privileged --name "${bake}" \
        --entrypoint /usr/local/bin/entrypoint "${BASE}" /sbin/init >/dev/null \
        || die "could not start the bake container"
      # shellcheck disable=SC2064
      trap "${CE} rm -f ${bake} >/dev/null 2>&1 || true" RETURN

      local i
      for i in $(seq 1 60); do
        "${CE}" exec "${bake}" ctr --namespace k8s.io version >/dev/null 2>&1 && break
        [[ ${i} -eq 60 ]] && die "containerd never started inside the bake container"
        sleep 2
      done

      local img
      while read -r img; do
        n=$((n+1))
        printf '\r  [%2d/%2d] %-58s' "${n}" "${total}" "${img:0:58}" >&2
        "${CE}" pull -q "${img}" >/dev/null 2>&1 \
          || { printf '\n' >&2; warn "could not pull ${img}; skipping"; continue; }
        "${CE}" save "${img}" 2>/dev/null \
          | "${CE}" exec -i "${bake}" ctr --namespace k8s.io images import --no-unpack - >/dev/null 2>&1 \
          || { printf '\n' >&2; warn "could not import ${img}"; }
      done < <(_images)
      printf '\n' >&2

      local got
      got="$("${CE}" exec "${bake}" ctr --namespace k8s.io images ls -q 2>/dev/null | wc -l | tr -d ' ')"
      ok "${got} images in the baked containerd store"

      "${CE}" stop -t 30 "${bake}" >/dev/null 2>&1 || true
      # Restore the entrypoint the base image ships; a committed container
      # otherwise keeps whatever was used to run it and kind will not boot.
      "${CE}" commit -q \
        --change 'ENTRYPOINT ["/usr/local/bin/entrypoint", "/sbin/init"]' \
        --change 'CMD []' \
        "${bake}" "${tag}" >/dev/null || die "commit failed"
      "${CE}" rm -f "${bake}" >/dev/null 2>&1 || true
      trap - RETURN
      ok "built ${tag}"
      echo "${tag}"
      ;;

    push)
      need gh
      local tag; tag="$(_tag)"
      "${CE}" image exists "${tag}" 2>/dev/null \
        || die "no local image ${tag} -- run: cluster.sh node-image build"
      gh auth token 2>/dev/null \
        | "${CE}" login ghcr.io -u "$(gh api user --jq .login)" --password-stdin >/dev/null \
        || die "could not log in to ghcr.io"
      log "pushing ${tag}"
      "${CE}" push "${tag}" || die "push failed"
      ok "pushed ${tag}"
      echo
      echo "  To use it, set in config.env:"
      echo "    NODE_IMAGE=\"${tag}\""
      ;;

    *) die "usage: cluster.sh node-image <list|build|push|tag>" ;;
  esac
}

_usage() {
  echo "usage: $(basename "$0") <preflight|pki|authn|registry|dns|up|down|node-image> [args]" >&2
  exit 2
}
[[ $# -ge 1 ]] || _usage
_sub="$1"; shift
case "${_sub}" in
  preflight) cmd_preflight "$@" ;;
  pki) cmd_pki "$@" ;;
  authn) cmd_authn "$@" ;;
  registry) cmd_registry "$@" ;;
  dns) cmd_dns "$@" ;;
  node-image) cmd_node_image "$@" ;;
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  *) _usage ;;
esac
