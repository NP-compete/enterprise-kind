#!/usr/bin/env bash
# The only things that modify your Mac. Both need sudo and are reversible.
#
# Usage: host-setup.sh <hosts|trust-ca> [args]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"


# Elevate without a terminal. `sudo` needs a TTY to prompt, and this is often
# run from an editor or wrapper that has none -- which fails with "a terminal
# is required to read the password" rather than asking. On macOS, osascript
# raises the native authorisation dialog instead, the same way the keychain
# prompt in trust-ca already does.
_sudo_cp() { # _sudo_cp <src> <dst>
  if sudo -n true 2>/dev/null; then
    sudo cp "$1" "$2"; return
  fi
  if [[ -t 0 ]]; then
    sudo cp "$1" "$2"; return
  fi
  if command -v osascript >/dev/null 2>&1; then
    log "no terminal for sudo; asking for authorisation with a dialog"
    osascript -e "do shell script \"cp '$1' '$2'\" with administrator privileges" >/dev/null \
      || die "authorisation cancelled or failed"
    return
  fi
  die "need root to write $2 and there is no terminal for sudo; run 'make hosts' in a terminal"
}

cmd_hosts() {
# Points the platform hostnames at 127.0.0.1 in /etc/hosts.
#
# macOS has no wildcard DNS, and *.localhost cannot be used (Go and musl
# resolve it to loopback without DNS, which breaks in-cluster OIDC), so the
# names need one real entry each. Needs sudo; `hosts.sh remove` undoes it.

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
    _sudo_cp "${tmp}" "${HOSTS_FILE}"
    rm -f "${tmp}"
    ok "added $(wc -w <<<"${PLATFORM_HOSTS}" | tr -d ' ') hostnames for ${BASE_DOMAIN}"
    ;;
  remove)
    log "removing the kind platform block from ${HOSTS_FILE} (sudo required)"
    tmp="$(mktemp)"
    sed "/^${BEGIN}\$/,/^${END}\$/d" "${HOSTS_FILE}" > "${tmp}"
    _sudo_cp "${tmp}" "${HOSTS_FILE}"
    rm -f "${tmp}"
    ok "removed"
    ;;
  *) die "usage: hosts.sh [add|remove|check]" ;;
esac
}

cmd_trust_ca() {
# Exports the cluster's private CA and adds it to the macOS login keychain so
# every https://*.${BASE_DOMAIN} URL is trusted. Undo with `make untrust-ca`.

CA_FILE="${ROOT_DIR}/.secrets/platform-root-ca.crt"
mkdir -p "${ROOT_DIR}/.secrets"

export_ca() {
  # pki.sh generates the CA on the host before the cluster exists, so prefer
  # that file; only fall back to reading it out of the cluster.
  if [[ -s "${CA_FILE}" ]]; then
    ok "using the CA at ${CA_FILE}"
    return
  fi
  kc -n cert-manager get secret platform-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CA_FILE}"
  [[ -s "${CA_FILE}" ]] || die "could not export the CA certificate"
  ok "CA written to ${CA_FILE}"
}

case "${1:-trust}" in
  export) export_ca ;;
  trust)
    export_ca
    # A rebuild mints a new CA with the same common name. Leaving the old one
    # behind means the browser keeps matching on name and rejecting the chain,
    # so clear every previous copy first.
    while security find-certificate -c "kind-platform-root-ca" \
            "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1; do
      security delete-certificate -c "kind-platform-root-ca" -t \
        "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || break
      warn "removed a previously trusted kind-platform-root-ca"
    done
    log "adding the CA to the login keychain (you will be prompted for your password)"
    if ! security add-trusted-cert -r trustRoot \
           -k "${HOME}/Library/Keychains/login.keychain-db" "${CA_FILE}"; then
      warn "could not add the CA to the keychain (no terminal for the password?)"
      warn "run 'make trust-ca' yourself to silence browser warnings"
      exit 0
    fi
    ok "CA trusted (sha256 $(openssl x509 -in "${CA_FILE}" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)...)"
    warn "fully quit and reopen Chrome -- it caches trust decisions per session"
    ;;
  untrust)
    [[ -s "${CA_FILE}" ]] || die "no exported CA at ${CA_FILE}"
    security remove-trusted-cert "${CA_FILE}" && ok "CA removed from the keychain"
    ;;
  *) die "usage: trust-ca.sh [trust|untrust|export]" ;;
esac
}

_usage() {
  echo "usage: $(basename "$0") <hosts|trust-ca> [args]" >&2
  exit 2
}
[[ $# -ge 1 ]] || _usage
_sub="$1"; shift
case "${_sub}" in
  hosts) cmd_hosts "$@" ;;
  trust-ca) cmd_trust_ca "$@" ;;
  *) _usage ;;
esac
