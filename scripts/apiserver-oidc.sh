#!/usr/bin/env bash
# Teach the API server to trust Keycloak, so a Headlamp SSO login becomes a real
# Kubernetes identity governed by RBAC instead of a token the cluster rejects.
#
# This runs after Keycloak is up rather than at cluster-creation time, because
# the API server needs the CA and the issuer to already exist.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Every control-plane node runs an API server, so each needs the hosts entry.
CP_NODES="$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep -- '-control-plane' | tr '\n' ' ')"
CP="$(printf '%s' "${CP_NODES}" | awk '{print $1}')"
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
CONFIG_PATH=/etc/kubernetes/policies/authentication-config.yaml
RENDERED="${ROOT_DIR}/cluster/policies/authentication-config.yaml"

cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist"

CA_PEM="$(kc -n cert-manager get secret platform-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)"
[[ -n "${CA_PEM}" ]] || die "platform CA not found; run make install first"
PLATFORM_CA_PEM_INDENTED8="$(sed 's/^/        /' <<<"${CA_PEM}")"
export PLATFORM_CA_PEM_INDENTED8

# The API server runs with host networking on the control-plane node and uses
# that node's resolver, not CoreDNS -- so it cannot resolve the ingress
# hostname. Point it at whichever node publishes the ingress controller.
ingress_ip="$(kc get nodes -l ingress-ready=true -o jsonpath='{.items[0].status.addresses[0].address}')"
[[ -n "${ingress_ip}" ]] || die "could not find the ingress-ready node"
host_entry="${ingress_ip} keycloak.${BASE_DOMAIN}"
hosts_changed=0
for cp in ${CP_NODES}; do
  "${CE}" exec "${cp}" grep -qxF "${host_entry}" /etc/hosts && continue
  hosts_changed=1
  # /etc/hosts is a bind mount, so sed -i (which renames) fails with EBUSY --
  # rewrite the file in place instead.
  log "pointing ${cp} at the ingress node for keycloak.${BASE_DOMAIN}"
  "${CE}" exec "${cp}" sh -c "grep -v 'keycloak\.${BASE_DOMAIN//./\\.}' /etc/hosts > /tmp/hosts.new; cat /tmp/hosts.new > /etc/hosts; echo '${host_entry}' >> /etc/hosts; rm -f /tmp/hosts.new"
done
ok "control plane resolves keycloak.${BASE_DOMAIN} -> ${ingress_ip}"

# v1 is GA from 1.32; fall back to v1beta1 on older control planes.
render_config() {
  AUTHN_API_VERSION="$1" envsubst '${AUTHN_API_VERSION} ${BASE_DOMAIN} ${URL_SUFFIX} ${PLATFORM_CA_PEM_INDENTED8}' \
    < "${ROOT_DIR}/cluster/policies/authentication-config.yaml.tmpl" > "${RENDERED}"
}

apiserver_healthy() {
  for _ in $(seq 1 60); do
    kc get --raw /readyz >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

patch_manifest() {
  local current patched
  current="$("${CE}" exec "${CP}" cat "${MANIFEST}")"
  patched="$(CONFIG_PATH="${CONFIG_PATH}" python3 -I "${ROOT_DIR}/scripts/apiserver_patch.py" <<<"${current}")"
  if [[ "${patched}" == "${current}" ]]; then
    ok "--authentication-config already set on the API server"
    return 1
  fi
  # Write via a temp file so the kubelet never observes a half-written manifest.
  "${CE}" exec -i "${CP}" sh -c "cat > /tmp/kube-apiserver.yaml && mv /tmp/kube-apiserver.yaml ${MANIFEST}" <<<"${patched}"
  log "patched the API server static pod manifest"
  return 0
}

# The container keeps the copy of /etc/hosts it was created with, and podman
# regenerates the node's file on every restart -- so a fresh hosts entry only
# takes effect once the API server container is recreated.
restart_apiserver() {
  # One at a time: with 3 control planes the cluster stays available throughout.
  for cp in ${CP_NODES}; do
    log "recreating the API server on ${cp}"
    "${CE}" exec "${cp}" sh -c "mv ${MANIFEST} /tmp/kube-apiserver.yaml"
    sleep 8
    "${CE}" exec "${cp}" sh -c "mv /tmp/kube-apiserver.yaml ${MANIFEST}"
    sleep 20
  done
}

for version in v1 v1beta1; do
  render_config "${version}"
  log "trying AuthenticationConfiguration ${version}"
  if ! patch_manifest && [[ ${hosts_changed} -eq 1 ]]; then
    restart_apiserver
  fi
  "${CE}" exec "${CP}" sh -c "touch ${MANIFEST}" # nudge the kubelet to re-read
  sleep 10
  if apiserver_healthy; then
    ok "API server accepted AuthenticationConfiguration ${version}"
    break
  fi
  warn "API server did not come back with ${version}"
  [[ "${version}" == "v1beta1" ]] && die "API server will not start with the OIDC config; check: ${CE} logs ${CP}"
done

kc apply -f "${ROOT_DIR}/platform/manifests/oidc-rbac.yaml" >/dev/null
ok "Keycloak groups bound to cluster RBAC (oidc:platform-admins -> cluster-admin)"
