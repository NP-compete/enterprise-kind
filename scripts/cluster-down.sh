#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if cluster_exists; then
  log "deleting cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "cluster deleted"
else
  warn "cluster '${CLUSTER_NAME}' not found"
fi

if [[ "${1:-}" == "--all" ]]; then
  "${ROOT_DIR}/scripts/registry.sh" stop
  "${CE}" volume rm "${REGISTRY_NAME}-data" >/dev/null 2>&1 && ok "registry volume removed" || true
  rm -rf "${BUILD_DIR}"
  ok "build artifacts removed (.secrets kept)"
else
  warn "registry '${REGISTRY_NAME}' left running -- 'make clean' removes it too"
fi
