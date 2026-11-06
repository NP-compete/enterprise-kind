#!/usr/bin/env bash
# Make the realm's clients match what the apps need, regardless of the order
# Keycloak happened to create things in during `--import-realm`.
#
# Realm import creates built-in client scopes (profile, email, roles, ...) and
# the clients in the same pass, so a client's `defaultClientScopes` can be
# applied before those scopes exist -- leaving the client with only the custom
# `groups` scope and tokens with no email or username. This reconciles them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REALM=platform
BASE="https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}"
CA="${ROOT_DIR}/.secrets/platform-root-ca.crt"
CLIENTS=(grafana argocd headlamp oauth2-proxy)
REQUIRED=(acr basic email profile roles web-origins groups)

curl_kc() { curl -sS --cacert "${CA}" --max-time 20 "$@"; }

log "waiting for Keycloak to answer"
for _ in $(seq 1 60); do
  curl_kc -o /dev/null -f "${BASE}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null && break
  sleep 5
done
curl_kc -o /dev/null -f "${BASE}/realms/${REALM}/.well-known/openid-configuration" \
  || die "Keycloak did not become ready at ${BASE}"

token="$(curl_kc -d client_id=admin-cli -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" -d grant_type=password \
  "${BASE}/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')"
[[ -n "${token}" ]] || die "could not authenticate to Keycloak as ${KEYCLOAK_ADMIN_USERNAME}"

api() { curl_kc -H "Authorization: Bearer ${token}" "$@"; }

scope_list() { api "${BASE}/admin/realms/${REALM}/client-scopes" | jq -r '.[] | "\(.name)=\(.id)"'; }

# The `groups` scope is ours, so create it here rather than in the realm import.
if ! scope_list | grep -q '^groups='; then
  log "creating the 'groups' client scope"
  api -X POST -H 'Content-Type: application/json' -o /dev/null \
    "${BASE}/admin/realms/${REALM}/client-scopes" -d '{
      "name": "groups",
      "description": "Group membership of the user",
      "protocol": "openid-connect",
      "attributes": {"include.in.token.scope": "true", "display.on.consent.screen": "false"},
      "protocolMappers": [{
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": false,
        "config": {
          "full.path": "false",
          "claim.name": "groups",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }]
    }'
fi

# --- Vault's OIDC client -----------------------------------------------
# Created here rather than in the realm import so it can be added to an
# already-imported realm without wiping it.
VAULT_SECRET_FILE="${ROOT_DIR}/.secrets/oidc-secret-vault"
if [[ -s "${VAULT_SECRET_FILE}" ]]; then
  vault_cid="$(api "${BASE}/admin/realms/${REALM}/clients?clientId=vault" | jq -r '.[0].id // empty')"
  vault_payload="$(jq -n --arg s "$(cat "${VAULT_SECRET_FILE}")" --arg d "${BASE}" '{
    clientId: "vault", name: "Vault", enabled: true, protocol: "openid-connect",
    publicClient: false, secret: $s,
    standardFlowEnabled: true, implicitFlowEnabled: false, directAccessGrantsEnabled: false,
    rootUrl: ($d + "/"),
    redirectUris: [
      ($d|sub("keycloak";"vault")) + "/ui/vault/auth/oidc/oidc/callback",
      "http://localhost:8250/oidc/callback"
    ],
    webOrigins: [($d|sub("keycloak";"vault"))]
  }')"
  if [[ -z "${vault_cid}" ]]; then
    api -X POST -H 'Content-Type: application/json' -o /dev/null \
      "${BASE}/admin/realms/${REALM}/clients" -d "${vault_payload}"
    ok "created Keycloak client 'vault'"
  else
    api -X PUT -H 'Content-Type: application/json' -o /dev/null \
      "${BASE}/admin/realms/${REALM}/clients/${vault_cid}" -d "${vault_payload}"
  fi
  CLIENTS+=(vault)
fi

# name -> id for every client scope in the realm
scope_ids="$(scope_list)"

changed=0
for client in "${CLIENTS[@]}"; do
  cid="$(api "${BASE}/admin/realms/${REALM}/clients?clientId=${client}" | jq -r '.[0].id // empty')"
  [[ -n "${cid}" ]] || { warn "client ${client} not found in realm ${REALM}"; continue; }
  have="$(api "${BASE}/admin/realms/${REALM}/clients/${cid}/default-client-scopes" | jq -r '.[].name')"
  for scope in "${REQUIRED[@]}"; do
    grep -qx "${scope}" <<<"${have}" && continue
    # `|| true`: pipefail would otherwise abort the script on a miss.
    sid="$(grep "^${scope}=" <<<"${scope_ids}" | cut -d= -f2 || true)"
    [[ -n "${sid}" ]] || { warn "realm has no client scope '${scope}'"; continue; }
    api -X PUT -o /dev/null \
      "${BASE}/admin/realms/${REALM}/clients/${cid}/default-client-scopes/${sid}"
    log "  ${client}: attached default scope '${scope}'"
    changed=$((changed + 1))
  done
done

if [[ ${changed} -eq 0 ]]; then
  ok "realm clients already have every required scope"
else
  ok "reconciled ${changed} client scope assignments"
fi
