#!/usr/bin/env bash
# Push a local image into the cluster registry.
#
#   make push IMG=myapp:1.0
#
# The registry is TLS-protected and requires auth, so this logs in first using
# the generated credentials in .secrets/.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMG="${1:?usage: push.sh <image:tag>}"
USER_FILE="${ROOT_DIR}/.secrets/registry-username"
PASS_FILE="${ROOT_DIR}/.secrets/registry-password"
[[ -s "${PASS_FILE}" ]] || die "no registry credentials -- run scripts/pki.sh"

REF="localhost:${REGISTRY_HOST_PORT}/${IMG}"
log "logging in to localhost:${REGISTRY_HOST_PORT}"
"${CE}" login --cert-dir "${ROOT_DIR}/.secrets" \
  -u "$(cat "${USER_FILE}")" -p "$(cat "${PASS_FILE}")" \
  "localhost:${REGISTRY_HOST_PORT}" >/dev/null 2>&1 \
  || "${CE}" login --tls-verify=false \
       -u "$(cat "${USER_FILE}")" -p "$(cat "${PASS_FILE}")" \
       "localhost:${REGISTRY_HOST_PORT}" >/dev/null \
  || die "registry login failed"

"${CE}" tag "${IMG}" "${REF}"
"${CE}" push --tls-verify=false "${REF}" >/dev/null || die "push failed"
ok "pushed ${REF}"
echo
echo "  In a pod:   image: ${REF}"
echo "  Needs:      imagePullSecrets: [{name: registry-creds}]"
echo "  The 'apps' namespace already has it on its default ServiceAccount."
