#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

S="${ROOT_DIR}/.secrets"
r() { [[ -s "${S}/$1" ]] && cat "${S}/$1" || echo '(run make install)'; }

apw="$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -z "${apw}" ]] && apw="(disabled or rotated)"

cat <<EOF

  ┌─ single sign-on ───────────────────────────────────────────────────────┐
   Sign in to every console below with one Keycloak account:

     ${SSO_ADMIN_USERNAME} / ${SSO_ADMIN_PASSWORD}   (group: platform-admins)
     ${SSO_VIEWER_USERNAME} / ${SSO_VIEWER_PASSWORD}   (group: platform-viewers)

   Keycloak    https://keycloak.${BASE_DOMAIN}${URL_SUFFIX}      realm: platform
     admin console:  ${KEYCLOAK_ADMIN_USERNAME} / ${KEYCLOAK_ADMIN_PASSWORD}
  └────────────────────────────────────────────────────────────────────────┘

  ┌─ consoles ─────────────────────────────────────────────────────────────┐
   Headlamp    https://headlamp.${BASE_DOMAIN}${URL_SUFFIX}
                 "Sign in with OIDC", or a token from: make token
   Argo CD     https://argocd.${BASE_DOMAIN}${URL_SUFFIX}
                 "LOG IN VIA KEYCLOAK", or break-glass admin / ${apw}
   Grafana     https://grafana.${BASE_DOMAIN}${URL_SUFFIX}
                 "Sign in with Keycloak", or break-glass admin / $(r grafana-admin-password)
   Prometheus  https://prometheus.${BASE_DOMAIN}${URL_SUFFIX}      (SSO via oauth2-proxy)
   Alertmanager https://alertmanager.${BASE_DOMAIN}${URL_SUFFIX}   (SSO via oauth2-proxy)
  └────────────────────────────────────────────────────────────────────────┘

   Registry    https://registry.${BASE_DOMAIN}${URL_SUFFIX}   (TLS + auth)
     browsing the UI prompts for the registry login:
       $(r registry-username) / $(r registry-password)
     push with:  make push IMG=myapp:1.0
     endpoint:   localhost:${REGISTRY_HOST_PORT}  (in-cluster: ${REGISTRY_NAME}:5000)
   Context    ${KUBECONTEXT}

   Certificates are signed by the cluster's private CA. Run 'make trust-ca'
   once to silence browser warnings, or accept the warning per host.

EOF
