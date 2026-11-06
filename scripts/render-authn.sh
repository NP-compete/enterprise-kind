#!/usr/bin/env bash
# Render the API server's OIDC authentication config from the pre-generated CA.
#
# Split out of apiserver-oidc.sh because it has to run before `kind create`:
# the API server mounts this file at kubeadm time. It is safe to point at a
# Keycloak that does not exist yet -- the API server starts anyway and retries
# the OIDC discovery in the background until Keycloak answers.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CA_CRT="${ROOT_DIR}/.secrets/platform-root-ca.crt"
[[ -s "${CA_CRT}" ]] || die "no platform CA at ${CA_CRT} -- run scripts/pki.sh first"

PLATFORM_CA_PEM_INDENTED8="$(sed 's/^/        /' "${CA_CRT}")"
export PLATFORM_CA_PEM_INDENTED8
export AUTHN_API_VERSION="${AUTHN_API_VERSION:-v1}"

envsubst '${AUTHN_API_VERSION} ${BASE_DOMAIN} ${URL_SUFFIX} ${PLATFORM_CA_PEM_INDENTED8}' \
  < "${ROOT_DIR}/cluster/policies/authentication-config.yaml.tmpl" \
  > "${ROOT_DIR}/cluster/policies/authentication-config.yaml"

ok "authentication-config.yaml rendered (issuer: https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}/realms/platform)"
