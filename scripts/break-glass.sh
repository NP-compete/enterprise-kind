#!/usr/bin/env bash
# Emergency access when Keycloak itself is down or misconfigured.
#
#   break-glass.sh on    -- re-enable the local login forms on Grafana and Argo CD
#   break-glass.sh off   -- back to Keycloak-only (same as `make install`)
#
# This deliberately edits the live cluster rather than the values files, so the
# next `make install` restores the SSO-only posture on its own.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-on}" in
  on)
    warn "re-enabling local logins -- this bypasses Keycloak"
    kc -n observability patch secret kps-grafana --type merge \
      -p "{\"stringData\":{\"admin-password\":\"$(cat "${ROOT_DIR}/.secrets/grafana-admin-password")\"}}" >/dev/null
    kc -n observability get cm kps-grafana -o json \
      | sed 's/disable_login_form = true/disable_login_form = false/; s/oauth_auto_login = true/oauth_auto_login = false/' \
      | kc apply -f - >/dev/null
    kc -n observability rollout restart deployment/kps-grafana >/dev/null
    kc -n argocd patch configmap argocd-cm --type merge -p '{"data":{"admin.enable":"true"}}' >/dev/null
    kc -n argocd rollout restart deployment/argocd-server >/dev/null
    ok "local logins enabled"
    echo
    echo "  Grafana  admin / $(cat "${ROOT_DIR}/.secrets/grafana-admin-password")"
    echo "  Argo CD  admin / $(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo '(secret deleted -- argocd admin initial-password reset)')"
    echo "  Headlamp use a ServiceAccount token: make token"
    echo
    warn "run 'make install' (or break-glass.sh off) to return to Keycloak-only"
    ;;
  off)
    "${ROOT_DIR}/scripts/platform-install.sh"
    ;;
  *) die "usage: break-glass.sh [on|off]" ;;
esac
