#!/usr/bin/env bash
# Exports the cluster's private CA and adds it to the macOS login keychain so
# every https://*.${BASE_DOMAIN} URL is trusted. Undo with `make untrust-ca`.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
