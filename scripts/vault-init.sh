#!/usr/bin/env bash
# Initialise and unseal Vault, then wire it up for External Secrets.
#
# Idempotent: safe to run on every install. Does nothing if Vault is already
# initialised and unsealed.
#
# THE LOCAL COMPROMISE, stated plainly: Vault's unseal keys are written to
# .secrets/vault-unseal-keys and replayed automatically after every restart.
# In production those shares are split between people and never co-located
# with the cluster. Here the alternative is typing three key shares by hand
# every time the laptop sleeps, which means nobody would run Vault at all.
# The keys are no more exposed than the passwords Vault is replacing -- but
# this is why Vault here is "secrets management you can develop against",
# not "secrets management that resists an attacker with disk access".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=vault
POD=vault-0
KEYS_FILE="${ROOT_DIR}/.secrets/vault-unseal-keys.json"
ROOT_FILE="${ROOT_DIR}/.secrets/vault-root-token"

# `vault status` exits 2 when sealed and 1 when uninitialised. Under
# `set -o pipefail` that makes `v status | grep -q ...` return non-zero
# regardless of what grep matched -- which previously meant the unseal block
# was skipped entirely and Vault was reported as stuck sealed.
v() { kc -n "${NS}" exec "${POD}" -- vault "$@" 2>/dev/null || true; }
vault_status() { v status || true; }

log "waiting for the Vault pod to be running"
for _ in $(seq 1 60); do
  phase="$(kc -n "${NS}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Running" ]] && break
  sleep 5
done
[[ "${phase}" == "Running" ]] || die "Vault pod never reached Running"

# --- initialise (first run only) -------------------------------------------
if ! vault_status | grep -q "Initialized  *true"; then
  if [[ -s "${KEYS_FILE}" ]]; then
    warn "Vault reports uninitialised but ${KEYS_FILE} exists"
    warn "its storage was wiped; the old keys cannot unseal a new Vault"
    mv "${KEYS_FILE}" "${KEYS_FILE}.stale-$(date +%s)"
    rm -f "${ROOT_FILE}"
  fi
  log "initialising Vault"
  kc -n "${NS}" exec "${POD}" -- vault operator init \
    -key-shares=3 -key-threshold=2 -format=json > "${KEYS_FILE}" \
    || die "vault operator init failed"
  chmod 600 "${KEYS_FILE}"
  jq -r '.root_token' "${KEYS_FILE}" > "${ROOT_FILE}"
  chmod 600 "${ROOT_FILE}"
  ok "Vault initialised (3 key shares, threshold 2)"
fi

# --- unseal -----------------------------------------------------------------
if vault_status | grep -q "Sealed  *true"; then
  log "unsealing"
  [[ -s "${KEYS_FILE}" ]] || die "no unseal keys at ${KEYS_FILE}"
  for i in 0 1 2; do
    vault_status | grep -q "Sealed  *false" && break
    key="$(jq -r ".unseal_keys_b64[$i] // empty" "${KEYS_FILE}")"
    [[ -n "${key}" ]] || break
    kc -n "${NS}" exec "${POD}" -- vault operator unseal "${key}" >/dev/null 2>&1 || true
  done
fi
vault_status | grep -q "Sealed  *false" || die "Vault is still sealed"
ok "Vault unsealed"

# --- configure for External Secrets ----------------------------------------
# Vault cannot disable the `token` auth method -- it is structural, every
# backend issues tokens. What it can do is not keep a permanent root token
# lying around: after first-run configuration the root token is revoked and
# this script authenticates with a scoped `installer` AppRole instead.
#
# Vault 2.x returns 403 on sys/generate-root/attempt, so regenerating root
# from the unseal keys is not an option here -- hence the AppRole.
INSTALLER_ROLE="${ROOT_DIR}/.secrets/vault-installer-role-id"
INSTALLER_SECRET="${ROOT_DIR}/.secrets/vault-installer-secret-id"

if [[ -s "${ROOT_FILE}" ]]; then
  ROOT_TOKEN="$(cat "${ROOT_FILE}")"
  FIRST_RUN=1
elif [[ -s "${INSTALLER_ROLE}" && -s "${INSTALLER_SECRET}" ]]; then
  ROOT_TOKEN="$(v write -field=token auth/approle/login \
    role_id="$(cat "${INSTALLER_ROLE}")" secret_id="$(cat "${INSTALLER_SECRET}")")"
  [[ -n "${ROOT_TOKEN}" ]] || die "installer AppRole login failed"
  ok "authenticated with the installer AppRole (no root token in use)"
else
  die "no root token and no installer credentials -- Vault cannot be reconfigured"
fi

# Authenticated Vault calls. NOTE: these MUST be defined before first use --
# `ex` is also a real binary (the ex line editor), so a missing function does
# not fail loudly, it silently succeeds and every check downstream lies.
ex()  { kc -n "${NS}" exec "${POD}"    -- env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@" 2>/dev/null; }
# Commands reading stdin need `exec -i`; without it the heredoc is dropped.
exi() { kc -n "${NS}" exec -i "${POD}" -- env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"; }

# --- secrets engine and machine auth ---------------------------------------
ex secrets list 2>/dev/null | grep -q '^platform/' \
  || { ex secrets enable -path=platform -version=2 kv >/dev/null && ok "kv-v2 enabled at platform/"; }

ex auth list 2>/dev/null | grep -q '^kubernetes/' \
  || { ex auth enable kubernetes >/dev/null && ok "kubernetes auth enabled"; }

# Vault validates ServiceAccount tokens against the API server it runs inside.
ex write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  disable_iss_validation=true >/dev/null

exi policy write external-secrets - >/dev/null <<'POLICY'
path "platform/data/*"     { capabilities = ["read", "list"] }
path "platform/metadata/*" { capabilities = ["read", "list"] }
POLICY

ex write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets ttl=24h >/dev/null
ok "kubernetes auth role 'external-secrets' bound"

# --- OIDC login against Keycloak -------------------------------------------
# Without this the Vault UI's OIDC button fails with "Error fetching role:
# permission denied" -- there is no oidc backend to fetch a role from.
VAULT_OIDC_SECRET="${ROOT_DIR}/.secrets/oidc-secret-vault"
if [[ -s "${VAULT_OIDC_SECRET}" ]]; then
  ex auth list 2>/dev/null | grep -q '^oidc/' \
    || { ex auth enable oidc >/dev/null && ok "oidc auth enabled"; }

  # Keycloak is served by the platform CA, which Vault does not trust by
  # default; hand it the CA inline rather than rebuilding the image.
  CA_PEM="$(cat "${ROOT_DIR}/.secrets/platform-root-ca.crt")"
  exi write auth/oidc/config - >/dev/null <<JSON || die "could not configure oidc auth"
{
  "oidc_discovery_url": "https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}/realms/platform",
  "oidc_client_id": "vault",
  "oidc_client_secret": "$(cat "${VAULT_OIDC_SECRET}")",
  "default_role": "default",
  "oidc_discovery_ca_pem": $(jq -Rs . <<<"${CA_PEM}")
}
JSON

  # Map the Keycloak group to a Vault policy.
  exi policy write platform-admin - >/dev/null <<'POLICY'
path "platform/*"   { capabilities = ["create","read","update","delete","list"] }
path "sys/mounts"   { capabilities = ["read","list"] }
path "sys/mounts/*" { capabilities = ["read","list"] }
path "auth/*"       { capabilities = ["read","list"] }
path "sys/policies/acl" { capabilities = ["read","list"] }
POLICY

  ex write auth/oidc/role/default \
    bound_audiences="vault" \
    allowed_redirect_uris="https://vault.${BASE_DOMAIN}${URL_SUFFIX}/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="preferred_username" \
    groups_claim="groups" \
    oidc_scopes="openid,profile,email,groups" \
    token_policies="platform-admin" \
    token_ttl=1h token_max_ttl=4h >/dev/null
  ok "OIDC login enabled (Keycloak -> policy platform-admin)"
fi

# --- AppRole for the Argo CD Vault Plugin ----------------------------------
# AVP authenticates with a role_id / secret_id pair rather than a Kubernetes
# ServiceAccount, because it runs as a sidecar in argocd-repo-server and
# resolves <path:...> placeholders at manifest-render time.
ex auth list 2>/dev/null | grep -q '^approle/' \
  || { ex auth enable approle >/dev/null && ok "approle auth enabled"; }

exi policy write argocd-vault-plugin - >/dev/null <<'POLICY'
path "platform/data/*"     { capabilities = ["read", "list"] }
path "platform/metadata/*" { capabilities = ["read", "list"] }
POLICY

ex write auth/approle/role/argocd-vault-plugin \
  token_policies=argocd-vault-plugin \
  token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

AVP_ROLE_ID="$(ex read -field=role_id auth/approle/role/argocd-vault-plugin/role-id)"
AVP_ROLE_FILE="${ROOT_DIR}/.secrets/avp-role-id"
AVP_SECRET_FILE="${ROOT_DIR}/.secrets/avp-secret-id"
printf '%s' "${AVP_ROLE_ID}" > "${AVP_ROLE_FILE}"; chmod 600 "${AVP_ROLE_FILE}"

# A secret_id is write-once: only mint a new one if we do not hold a valid one.
need_secret_id=1
if [[ -s "${AVP_SECRET_FILE}" ]]; then
  if ex write -field=ttl auth/approle/role/argocd-vault-plugin/secret-id-accessor/lookup \
       secret_id_accessor="$(cat "${ROOT_DIR}/.secrets/avp-secret-id-accessor" 2>/dev/null || echo none)" \
       >/dev/null 2>&1; then
    need_secret_id=0
  fi
fi
if [[ ${need_secret_id} -eq 1 ]]; then
  sid_json="$(ex write -format=json -f auth/approle/role/argocd-vault-plugin/secret-id)"
  printf '%s' "$(jq -r '.data.secret_id' <<<"${sid_json}")" > "${AVP_SECRET_FILE}"
  printf '%s' "$(jq -r '.data.secret_id_accessor' <<<"${sid_json}")" > "${ROOT_DIR}/.secrets/avp-secret-id-accessor"
  chmod 600 "${AVP_SECRET_FILE}" "${ROOT_DIR}/.secrets/avp-secret-id-accessor"
fi

# Hand them to Argo CD in the form the plugin expects.
kc get namespace argocd >/dev/null 2>&1 && kc -n argocd create secret generic argocd-vault-plugin-credentials \
  --from-literal=AVP_TYPE=vault \
  --from-literal=AVP_AUTH_TYPE=approle \
  --from-literal=VAULT_ADDR=http://vault.vault.svc.cluster.local:8200 \
  --from-literal=AVP_ROLE_ID="${AVP_ROLE_ID}" \
  --from-literal=AVP_SECRET_ID="$(cat "${AVP_SECRET_FILE}")" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "AppRole for argocd-vault-plugin ready (argocd/argocd-vault-plugin-credentials)"

# --- seed the platform secrets ---------------------------------------------
# Vault becomes the source of truth; .secrets/ keeps only what bootstraps it.
seed() { # seed <path> <key>=<file> ...
  local p="$1"; shift
  local args=()
  for kv in "$@"; do
    local k="${kv%%=*}" f="${kv#*=}"
    [[ -s "${f}" ]] && args+=("${k}=$(cat "${f}")")
  done
  [[ ${#args[@]} -gt 0 ]] && ex kv put "platform/${p}" "${args[@]}" >/dev/null
}
S="${ROOT_DIR}/.secrets"
seed grafana       admin-password="${S}/grafana-admin-password"
seed keycloak      admin-password="${S}/keycloak-admin-password" db-password="${S}/keycloak-db-password"
seed registry      username="${S}/registry-username" password="${S}/registry-password"
seed object-store  access-key="${S}/s3-access-key" secret-key="${S}/s3-secret-key"
seed oidc          grafana="${S}/oidc-secret-grafana" argocd="${S}/oidc-secret-argocd" \
                   headlamp="${S}/oidc-secret-headlamp" oauth2-proxy="${S}/oidc-secret-oauth2-proxy"
ok "platform secrets seeded into platform/ (kv-v2)"

# --- hand over to a scoped installer identity, then drop root ---------------
# From here the only human login is OIDC via Keycloak. Re-runs of this script
# use the installer AppRole below, which can manage configuration but is not
# root and can be revoked independently.
exi policy write installer - >/dev/null <<'POLICY'
path "sys/auth"                 { capabilities = ["read","list"] }
path "sys/auth/*"               { capabilities = ["create","read","update","delete","sudo"] }
path "sys/mounts"               { capabilities = ["read","list"] }
path "sys/mounts/*"             { capabilities = ["create","read","update","delete"] }
path "sys/policies/acl/*"       { capabilities = ["create","read","update","delete","list"] }
path "auth/*"                   { capabilities = ["create","read","update","delete","list"] }
path "platform/*"               { capabilities = ["create","read","update","delete","list"] }
POLICY

ex write auth/approle/role/installer \
  token_policies=installer token_ttl=30m token_max_ttl=1h \
  secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

if [[ ! -s "${INSTALLER_SECRET}" ]]; then
  ex read -field=role_id auth/approle/role/installer/role-id > "${INSTALLER_ROLE}"
  ex write -f -field=secret_id auth/approle/role/installer/secret-id > "${INSTALLER_SECRET}"
  chmod 600 "${INSTALLER_ROLE}" "${INSTALLER_SECRET}"
  ok "installer AppRole created"
fi

if [[ "${FIRST_RUN:-0}" == "1" ]]; then
  if ex token revoke -self >/dev/null 2>&1; then
    rm -f "${ROOT_FILE}"
    ok "root token revoked -- OIDC via Keycloak is now the only human login"
  else
    warn "could not revoke the root token; it remains at ${ROOT_FILE}"
  fi
fi
