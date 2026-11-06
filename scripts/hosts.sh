#!/usr/bin/env bash
# Points the platform hostnames at 127.0.0.1 in /etc/hosts.
#
# macOS has no wildcard DNS, and *.localhost cannot be used (Go and musl
# resolve it to loopback without DNS, which breaks in-cluster OIDC), so the
# names need one real entry each. Needs sudo; `hosts.sh remove` undoes it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEGIN="# BEGIN kind platform (${CLUSTER_NAME})"
END="# END kind platform (${CLUSTER_NAME})"
HOSTS_FILE=/etc/hosts

entries() {
  local line="127.0.0.1"
  for h in ${PLATFORM_HOSTS}; do line+=" ${h}.${BASE_DOMAIN}"; done
  printf '%s\n%s\n::1 %s\n%s\n' "${BEGIN}" "${line}" \
    "$(for h in ${PLATFORM_HOSTS}; do printf '%s ' "${h}.${BASE_DOMAIN}"; done)" "${END}"
}

missing() {
  for h in ${PLATFORM_HOSTS}; do
    grep -qE "^[^#]*[[:space:]]${h}\.${BASE_DOMAIN}([[:space:]]|$)" "${HOSTS_FILE}" || return 0
  done
  return 1
}

case "${1:-add}" in
  check)
    if missing; then
      warn "some ${BASE_DOMAIN} hostnames are not in ${HOSTS_FILE} -- run: make hosts"
      exit 1
    fi
    ok "all ${BASE_DOMAIN} hostnames resolve via ${HOSTS_FILE}"
    ;;
  add)
    log "updating ${HOSTS_FILE} (sudo required)"
    tmp="$(mktemp)"
    sed "/^${BEGIN}\$/,/^${END}\$/d" "${HOSTS_FILE}" > "${tmp}"
    entries >> "${tmp}"
    sudo cp "${tmp}" "${HOSTS_FILE}"
    rm -f "${tmp}"
    ok "added $(wc -w <<<"${PLATFORM_HOSTS}" | tr -d ' ') hostnames for ${BASE_DOMAIN}"
    ;;
  remove)
    log "removing the kind platform block from ${HOSTS_FILE} (sudo required)"
    tmp="$(mktemp)"
    sed "/^${BEGIN}\$/,/^${END}\$/d" "${HOSTS_FILE}" > "${tmp}"
    sudo cp "${tmp}" "${HOSTS_FILE}"
    rm -f "${tmp}"
    ok "removed"
    ;;
  *) die "usage: hosts.sh [add|remove|check]" ;;
esac
