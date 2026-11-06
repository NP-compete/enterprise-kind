#!/usr/bin/env bash
# Common helpers. Source, do not execute.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
mkdir -p "${BUILD_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/config.env"

export CLUSTER_NAME NODE_IMAGE HTTP_PORT HTTPS_PORT API_SERVER_PORT BASE_DOMAIN \
       REGISTRY_NAME REGISTRY_HOST_PORT CONTAINER_ENGINE NODE_IMAGE_ETCD PLATFORM_HOSTS SEALED_SECRETS_VERSION
export KUBECONTEXT="kind-${CLUSTER_NAME}"
# Port suffix for user-facing URLs; empty on the standard https port.
if [[ "${HTTPS_PORT}" == "443" ]]; then export URL_SUFFIX=""; else export URL_SUFFIX=":${HTTPS_PORT}"; fi
export POLICY_DIR="${ROOT_DIR}/cluster/policies"

if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi
CE="${CONTAINER_ENGINE}"

_c()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
log() { printf '%s %s\n' "$(_c '1;34' '==>')" "$*" >&2; }
ok()  { printf '%s %s\n' "$(_c '1;32' ' ok')" "$*" >&2; }
warn(){ printf '%s %s\n' "$(_c '1;33' ' !!')" "$*" >&2; }
die() { printf '%s %s\n' "$(_c '1;31' 'ERR')" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

kc() { kubectl --context "${KUBECONTEXT}" "$@"; }

# `kind get clusters` can fail transiently when the container engine is busy,
# which previously aborted an install against a perfectly healthy cluster.
cluster_exists() {
  local i
  for i in 1 2 3; do
    if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then return 0; fi
    # Distinguish "engine hiccup" from "genuinely absent": if the API answers,
    # the cluster is there regardless of what kind just told us.
    if kubectl --context "${KUBECONTEXT}" get --raw /readyz >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# helm_install <release> <namespace> <chart> <version> [values-file...] [-- extra args]
helm_install() {
  local release="$1" ns="$2" chart="$3" version="$4"; shift 4
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; args+=("$@"); break ;;
      *)  [[ -f "$1" ]] && args+=(-f "$1") || die "values file not found: $1"; shift ;;
    esac
  done
  # A release left in pending-* by an interrupted run blocks every later upgrade.
  local status
  status="$(helm status "${release}" -n "${ns}" --kube-context "${KUBECONTEXT}" -o json 2>/dev/null \
            | jq -r '.info.status' 2>/dev/null || true)"
  case "${status}" in
    pending-install)
      warn "${release} is stuck in pending-install; removing it first"
      helm uninstall "${release}" -n "${ns}" --kube-context "${KUBECONTEXT}" --wait >/dev/null 2>&1 || true
      ;;
    pending-upgrade|pending-rollback)
      warn "${release} is stuck in ${status}; rolling back"
      helm rollback "${release}" -n "${ns}" --kube-context "${KUBECONTEXT}" --wait >/dev/null 2>&1 || true
      ;;
  esac

  log "helm: ${release} (${chart}:${version}) -> ns/${ns}"
  helm upgrade --install "${release}" "${chart}" \
    --version "${version}" \
    --namespace "${ns}" --create-namespace \
    --kube-context "${KUBECONTEXT}" \
    --wait --timeout 15m \
    "${args[@]}"
}

wait_rollout() {
  local ns="$1"; shift
  for obj in "$@"; do
    kc -n "${ns}" rollout status "${obj}" --timeout=10m >/dev/null || warn "rollout not ready: ${ns}/${obj}"
  done
}
