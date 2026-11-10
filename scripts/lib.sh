#!/usr/bin/env bash
# Common helpers. Source, do not execute.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
mkdir -p "${BUILD_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/config.env"

export CLUSTER_NAME NODE_IMAGE HTTP_PORT HTTPS_PORT API_SERVER_PORT BASE_DOMAIN \
       REGISTRY_NAME REGISTRY_HOST_PORT CONTAINER_ENGINE NODE_IMAGE_ETCD PLATFORM_HOSTS SEALED_SECRETS_VERSION COSIGN_VERSION \
       PG_INSTANCES CHART_OPENSHELL AGENT_SANDBOX_VERSION
# Identity passwords are generated into .secrets/ on first install rather than
# living in config.env. Resolve them here so every script -- urls, smoke
# tests, keycloak-reconcile, demo -- sees the same value without each one
# re-implementing the lookup. An explicit setting still wins: config.env's
# `${VAR:-}` leaves a value set in the environment intact, and this only fills
# the blank.
_secret() { local f="${ROOT_DIR}/.secrets/$1"; [[ -s "${f}" ]] && cat "${f}" || true; }
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(_secret keycloak-admin-password)}"
SSO_ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-$(_secret sso-admin-password)}"
SSO_VIEWER_PASSWORD="${SSO_VIEWER_PASSWORD:-$(_secret sso-viewer-password)}"
export KEYCLOAK_ADMIN_PASSWORD SSO_ADMIN_PASSWORD SSO_VIEWER_PASSWORD

export KUBECONTEXT="kind-${CLUSTER_NAME}"
# Port suffix for user-facing URLs; empty on the standard https port.
if [[ "${HTTPS_PORT}" == "443" ]]; then export URL_SUFFIX=""; else export URL_SUFFIX=":${HTTPS_PORT}"; fi
export POLICY_DIR="${ROOT_DIR}/cluster/policies"

if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi
# Used by the scripts that source this file, not by lib.sh itself.
# shellcheck disable=SC2034
CE="${CONTAINER_ENGINE}"

# The whitelist handed to envsubst wherever platform YAML is rendered.
#
# It MUST be a whitelist. An unrestricted envsubst also eats the charts' own
# `$__file{...}`, `$__env{...}` and `$${...}` syntax -- `$__file{/path}`
# becomes `{/path}`, which YAML then parses as a flow mapping and the chart
# rejects as "expected string, got map". Defined here so the installer and
# the linter cannot drift apart on it.
export PLATFORM_SUBST='${BASE_DOMAIN} ${URL_SUFFIX} ${CLUSTER_NAME} ${GRAFANA_ADMIN_PASSWORD}
       ${REGISTRY_NAME} ${REGISTRY_HOST_PORT} ${KEYCLOAK_ADMIN_PASSWORD}
       ${KEYCLOAK_ADMIN_USERNAME} ${SSO_ADMIN_USERNAME} ${SSO_VIEWER_USERNAME}
       ${KEYCLOAK_DB_PASSWORD} ${SSO_ADMIN_PASSWORD} ${SSO_VIEWER_PASSWORD}
       ${OIDC_SECRET_GRAFANA} ${OIDC_SECRET_ARGOCD} ${OIDC_SECRET_HEADLAMP}
       ${OIDC_SECRET_OAUTH2PROXY} ${OAUTH2_PROXY_COOKIE_SECRET} ${PLATFORM_CA_PEM_INDENTED}
       ${REALM_CHECKSUM} ${PORTAL_CONFIG_CHECKSUM} ${REGISTRY_CONTAINER_IP}
       ${S3_CONFIG_CHECKSUM} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} ${NODE_IMAGE_ETCD}
       ${COSIGN_PUBLIC_KEY_INDENTED} ${PLATFORM_CA_PEM_INDENTED6}
       ${PG_INSTANCES} ${GRAFANA_DB_PASSWORD} ${OIDC_SECRET_TEMPLATE_AGENT}'

_c()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
# Elapsed wall time since the TOP-LEVEL command started. Exported, because
# platform-install.sh shells out to cluster.sh and identity.sh and bash
# resets SECONDS in every new process -- which made the clock restart
# mid-build and the per-step costs derived from it meaningless.
export BUILD_T0="${BUILD_T0:-$(date +%s)}"
_el() { local d=$(( $(date +%s) - BUILD_T0 )); printf '%02d:%02d' $((d/60)) $((d%60)); }

# Per-step cost accounting, written to a file so a nested script's steps land
# in the same ledger as its parent's.
export STEP_LEDGER="${STEP_LEDGER:-${BUILD_DIR}/steps.tsv}"
# Truncated by the top-level script only, so nested scripts append.
[[ -n "${STEP_LEDGER_OWNER:-}" ]] || { export STEP_LEDGER_OWNER=$$; : > "${STEP_LEDGER}" 2>/dev/null || true; }
step() {
  printf '%s\t%s\n' "$(( $(date +%s) - BUILD_T0 ))" "$*" >> "${STEP_LEDGER}" 2>/dev/null || true
  log "$@"
}
# step_report -- the slowest steps of this run, so the next optimisation
# targets something measured rather than something assumed.
step_report() {
  [[ -s "${STEP_LEDGER}" ]] || return 0
  printf '\n%s\n' "$(_c '1;34' 'slowest steps')" >&2
  awk -F'\t' 'NR>1{printf "%6ds  %s\n", $1-p, m} {p=$1; m=$2}' "${STEP_LEDGER}" \
    | sort -rn | head -10 | sed 's/^/  /' >&2
  printf '  %6ss  TOTAL\n\n' "$(( $(date +%s) - BUILD_T0 ))" >&2
}
log() { printf '%s %s %s\n' "$(_c '0;90' "[$(_el)]")" "$(_c '1;34' '==>')" "$*" >&2; }
ok()  { printf '%s %s %s\n' "$(_c '0;90' "[$(_el)]")" "$(_c '1;32' ' ok')" "$*" >&2; }
warn(){ printf '%s %s %s\n' "$(_c '0;90' "[$(_el)]")" "$(_c '1;33' ' !!')" "$*" >&2; }
die() { printf '%s %s %s\n' "$(_c '0;90' "[$(_el)]")" "$(_c '1;31' 'ERR')" "$*" >&2; exit 1; }

# hint <lines...> -- what to actually do about a failure. Printed by the
# error traps below, so a broken run ends with a command to run rather than
# a stack of helm output.
hint() {
  printf '\n%s\n' "$(_c '1;33' 'what to do:')" >&2
  local l; for l in "$@"; do printf '  %s\n' "${l}" >&2; done
  printf '\n' >&2
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# rand_alnum <length> -- random A-Za-z0-9 string.
#
# Deliberately not `tr -dc ... </dev/urandom | head -c N`: /dev/urandom never
# ends, so `head` exits first and `tr` dies of SIGPIPE, which under
# `set -o pipefail` aborts the whole script. It is a race -- small enough
# writes finish before head closes -- so it only bites on a fresh .secrets/.
# Reading a bounded chunk makes tr terminate on its own.
rand_alnum() {
  local len="${1:-24}" chars
  chars="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 8192 /dev/urandom))"
  [[ ${#chars} -ge ${len} ]] || die "not enough entropy for a ${len}-char secret"
  printf '%s' "${chars:0:${len}}"
}

kc() { kubectl --context "${KUBECONTEXT}" "$@"; }

# `kind get clusters` can fail transiently when the container engine is busy,
# which previously aborted an install against a perfectly healthy cluster.
cluster_exists() {
  for _ in 1 2 3; do
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

  step "helm: ${release} (${chart}:${version}) -> ns/${ns}"
  local wait_args=(--wait --timeout 15m)
  [[ "${HELM_WAIT:-1}" == "0" ]] && wait_args=(--timeout 15m)
  helm upgrade --install "${release}" "${chart}" \
    --version "${version}" \
    --namespace "${ns}" --create-namespace \
    --kube-context "${KUBECONTEXT}" \
    "${wait_args[@]}" \
    "${args[@]}"
}

# helm_install_nw -- install without blocking on readiness.
#
# `helm --wait` is what the install actually spends its time on: it blocks
# until every pod of a release is Ready, serially, even when nothing later
# needs that release. Kubernetes is perfectly happy to roll several out at
# once, so charts with no in-install dependents skip the wait and are
# collected by wait_all_ready() at the end.
#
# Use helm_install (which waits) for anything whose objects are consumed by
# a later step: cert-manager before its Issuers, CNPG before the Cluster CR,
# Keycloak before the realm reconcile, Kyverno before its policies.
helm_install_nw() { HELM_WAIT=0 helm_install "$@"; }

# wait_all_ready -- single barrier for everything installed without --wait.
# Waits for Deployments to report Available and StatefulSets to finish their
# rollout, in parallel, so the cost is the slowest component rather than the
# sum of all of them.
wait_all_ready() {
  local timeout="${1:-10m}" pids=() obj rc=0
  log "waiting for every workload to become ready"
  while read -r ns kind name; do
    [[ -z "${ns}" ]] && continue
    ( kc -n "${ns}" rollout status "${kind}/${name}" --timeout="${timeout}" >/dev/null 2>&1 \
      || { warn "not ready: ${ns}/${kind}/${name}"; exit 1; } ) &
    pids+=($!)
  done < <(kc get deploy,statefulset -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.kind}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
           | awk 'tolower($2)=="deployment"{print $1, "deployment", $3} tolower($2)=="statefulset"{print $1, "statefulset", $3}')
  for obj in "${pids[@]}"; do wait "${obj}" || rc=1; done
  [[ ${rc} -eq 0 ]] && ok "all workloads ready" \
                    || warn "some workloads are not ready; 'make doctor' will name them"
  return 0
}

wait_rollout() {
  local ns="$1"; shift
  for obj in "$@"; do
    kc -n "${ns}" rollout status "${obj}" --timeout=10m >/dev/null || warn "rollout not ready: ${ns}/${obj}"
  done
}
