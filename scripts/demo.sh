#!/usr/bin/env bash
# Deploys / removes the reference workload in the `apps` tenant namespace.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBST='${BASE_DOMAIN}'
rendered="${BUILD_DIR}/podinfo.yaml"
envsubst "${SUBST}" < "${ROOT_DIR}/apps/podinfo/deployment.yaml" > "${rendered}"

case "${1:-apply}" in
  apply)
    kc apply -f "${ROOT_DIR}/platform/manifests/tenant-namespace.yaml" >/dev/null
    kc apply -f "${rendered}"
    wait_rollout apps deployment/podinfo
    suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"
    ok "podinfo up at https://podinfo.${BASE_DOMAIN}${suffix}"
    ;;
  delete)
    kc delete -f "${rendered}" --ignore-not-found
    ok "podinfo removed"
    ;;
  load)
    # Generate traffic so the dashboards and traces have something to show.
    suffix=""; [[ "${HTTPS_PORT}" != "443" ]] && suffix=":${HTTPS_PORT}"
    log "sending traffic to podinfo for 60s"
    end=$(( $(date +%s) + 60 ))
    while [[ $(date +%s) -lt ${end} ]]; do
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/" || true
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/delay/1" || true
      curl -sk -o /dev/null "https://podinfo.${BASE_DOMAIN}${suffix}/status/500" || true
    done
    ok "traffic generated"
    ;;
  *) die "usage: demo.sh [apply|delete|load]" ;;
esac
