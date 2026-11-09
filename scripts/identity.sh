#!/usr/bin/env bash
# Identity and secrets subsystems. Each is idempotent and independently re-runnable.
#
# Usage: identity.sh <keycloak|apiserver|vault> [args]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd_keycloak() {
# Make the realm's clients match what the apps need, regardless of the order
# Keycloak happened to create things in during `--import-realm`.
#
# Realm import creates built-in client scopes (profile, email, roles, ...) and
# the clients in the same pass, so a client's `defaultClientScopes` can be
# applied before those scopes exist -- leaving the client with only the custom
# `groups` scope and tokens with no email or username. This reconciles them.

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
}

cmd_apiserver() {
# Teach the API server to trust Keycloak, so a Headlamp SSO login becomes a real
# Kubernetes identity governed by RBAC instead of a token the cluster rejects.
#
# This runs after Keycloak is up rather than at cluster-creation time, because
# the API server needs the CA and the issuer to already exist.

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
}

cmd_vault() {
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

NS=vault
# Configuration goes through vault-0; a standby forwards to the active node.
# Unsealing cannot be forwarded -- each node holds its own seal -- so every
# pod in PODS is unsealed individually.
POD=vault-0
# From the StatefulSet's DESIRED count, not by listing pods: this runs right
# after `helm install`, when later pods may not exist yet. Works unchanged
# for a 1-pod standalone Vault or a 3-pod Raft cluster.
VAULT_REPLICAS="$(kc -n "${NS}" get statefulset vault -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
[[ "${VAULT_REPLICAS}" =~ ^[0-9]+$ ]] && [[ "${VAULT_REPLICAS}" -gt 0 ]] || VAULT_REPLICAS=1
PODS=()
for i in $(seq 0 $((VAULT_REPLICAS - 1))); do PODS+=("vault-${i}"); done
# Raft quorum is a majority; a single node is its own majority.
QUORUM=$(( ${#PODS[@]} / 2 + 1 ))
KEYS_FILE="${ROOT_DIR}/.secrets/vault-unseal-keys.json"
ROOT_FILE="${ROOT_DIR}/.secrets/vault-root-token"

# `vault status` exits 2 when sealed and 1 when uninitialised. Under
# `set -o pipefail` that makes `v status | grep -q ...` return non-zero
# regardless of what grep matched -- which previously meant the unseal block
# was skipped entirely and Vault was reported as stuck sealed.
v() { kc -n "${NS}" exec "${POD}" -- vault "$@" 2>/dev/null || true; }
vault_status() { v status || true; }
pod_status() { kc -n "${NS}" exec "$1" -- vault status 2>/dev/null || true; }

# A sealed or not-yet-joined Vault never becomes Ready, so `rollout status`
# would block forever here. Running is the most we can wait for.
log "waiting for the Vault pods to be running"
for p in "${PODS[@]}"; do
  phase=""
  for _ in $(seq 1 60); do
    phase="$(kc -n "${NS}" get pod "${p}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Running" ]] && break
    sleep 5
  done
  [[ "${phase}" == "Running" ]] || die "Vault pod ${p} never reached Running"
done

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

# --- unseal every node ------------------------------------------------------
# Standbys join via retry_join on their own, but a joined node is still a
# sealed node until the same key shares are applied to it.
unseal_pod() {
  local p="$1" i key
  pod_status "${p}" | grep -q "Sealed  *false" && return 0
  [[ -s "${KEYS_FILE}" ]] || die "no unseal keys at ${KEYS_FILE}"
  for i in 0 1 2; do
    pod_status "${p}" | grep -q "Sealed  *false" && return 0
    key="$(jq -r ".unseal_keys_b64[$i] // empty" "${KEYS_FILE}")"
    [[ -n "${key}" ]] || break
    kc -n "${NS}" exec "${p}" -- vault operator unseal "${key}" >/dev/null 2>&1 || true
  done
  pod_status "${p}" | grep -q "Sealed  *false"
}

log "unsealing ${#PODS[@]} Vault node(s)"
# vault-0 first: until the bootstrap node is unsealed and active there is no
# leader for the others' retry_join to reach.
unseal_pod vault-0 || die "vault-0 is still sealed"
ok "vault-0 unsealed"

for p in "${PODS[@]:1}"; do
  # Give retry_join a chance to land before deciding the node is broken.
  for _ in $(seq 1 24); do
    unseal_pod "${p}" && break
    sleep 5
  done
  if pod_status "${p}" | grep -q "Sealed  *false"; then
    ok "${p} unsealed and joined"
  else
    warn "${p} is still sealed -- the cluster is up but degraded"
  fi
done

# Quorum, not just liveness: with 3 nodes Raft needs 2 to agree, so report
# what the cluster actually has rather than that vault-0 answered.
UNSEALED=0
for p in "${PODS[@]}"; do
  pod_status "${p}" | grep -q "Sealed  *false" && UNSEALED=$((UNSEALED + 1))
done
[[ ${UNSEALED} -ge ${QUORUM} ]] || die "only ${UNSEALED}/${#PODS[@]} Vault nodes unsealed -- need ${QUORUM} for quorum"
ok "Vault unsealed (${UNSEALED}/${#PODS[@]} nodes, quorum held)"

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
  if [[ -z "${ROOT_TOKEN}" ]]; then
    # Almost always means these credentials belong to a *previous* Vault:
    # .secrets/ outlives `make clean`, so a rebuilt cluster finds files that
    # look valid and are not. Same failure the unseal-keys check above
    # already handles -- say so, rather than just reporting a failed login.
    die "installer AppRole login failed.
     These credentials do not belong to this Vault -- almost certainly left
     over from an earlier cluster, since .secrets/ survives 'make clean'.
     This Vault's root token is already revoked, so there is no way back in.
     Wipe Vault's storage and let it re-initialise:
       kubectl -n vault delete statefulset vault --cascade=foreground
       kubectl -n vault delete pvc -l app.kubernetes.io/name=vault
       rm -f ${ROOT_DIR}/.secrets/vault-unseal-keys.json \\
             ${ROOT_DIR}/.secrets/vault-installer-* \\
             ${ROOT_DIR}/.secrets/avp-*
       make install"
  fi
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

# Mint if absent OR if the credentials on disk do not work against *this*
# Vault: .secrets/ survives `make clean`, so a rebuilt cluster finds the
# previous Vault's role-id and secret-id. Verify while root is still live --
# after it is revoked there is no way to re-mint.
need_installer=0
if [[ ! -s "${INSTALLER_SECRET}" || ! -s "${INSTALLER_ROLE}" ]]; then
  need_installer=1
elif ! ex write -field=token auth/approle/login \
       role_id="$(cat "${INSTALLER_ROLE}")" \
       secret_id="$(cat "${INSTALLER_SECRET}")" >/dev/null 2>&1; then
  warn "installer credentials on disk do not work against this Vault (stale from an earlier cluster); re-minting"
  need_installer=1
fi
if [[ ${need_installer} -eq 1 ]]; then
  ex read -field=role_id auth/approle/role/installer/role-id > "${INSTALLER_ROLE}"
  ex write -f -field=secret_id auth/approle/role/installer/secret-id > "${INSTALLER_SECRET}"
  chmod 600 "${INSTALLER_ROLE}" "${INSTALLER_SECRET}"
  ok "installer AppRole credentials minted"
fi

# Never revoke root on the strength of an unverified fallback. If this login
# does not work, keep the root token and say so -- a Vault with a root token
# still on disk is a smaller problem than a Vault nobody can administer.
if ! ex write -field=token auth/approle/login \
     role_id="$(cat "${INSTALLER_ROLE}")" \
     secret_id="$(cat "${INSTALLER_SECRET}")" >/dev/null 2>&1; then
  warn "installer AppRole still cannot log in; keeping the root token at ${ROOT_FILE}"
  SKIP_ROOT_REVOKE=1
fi

if [[ "${FIRST_RUN:-0}" == "1" && "${SKIP_ROOT_REVOKE:-0}" != "1" ]]; then
  if ex token revoke -self >/dev/null 2>&1; then
    rm -f "${ROOT_FILE}"
    ok "root token revoked -- OIDC via Keycloak is now the only human login"
  else
    warn "could not revoke the root token; it remains at ${ROOT_FILE}"
  fi
fi
}

_usage() {
  echo "usage: $(basename "$0") <keycloak|apiserver|vault> [args]" >&2
  exit 2
}
[[ $# -ge 1 ]] || _usage
_sub="$1"; shift
case "${_sub}" in
  keycloak) cmd_keycloak "$@" ;;
  apiserver) cmd_apiserver "$@" ;;
  vault) cmd_vault "$@" ;;
  *) _usage ;;
esac
