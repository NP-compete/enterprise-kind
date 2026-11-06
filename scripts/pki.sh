#!/usr/bin/env bash
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
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "${REG_PASS_FILE}"
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
