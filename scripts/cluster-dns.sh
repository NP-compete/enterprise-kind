#!/usr/bin/env bash
# Make the platform's public hostnames resolvable from inside the cluster.
#
# Grafana, Argo CD, Headlamp and oauth2-proxy all perform server-side OIDC calls
# to https://keycloak.${BASE_DOMAIN}. That name only exists in the browser unless
# CoreDNS knows about it, so point *.${BASE_DOMAIN} at the ingress controller.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECTED="name regex (.*)\\.${BASE_DOMAIN//./\\.}\\.?\$ ingress-nginx-controller"

current="$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
if grep -qF "${EXPECTED}" <<<"${current}"; then
  ok "CoreDNS already resolves *.${BASE_DOMAIN} to the ingress controller"
  exit 0
fi

log "teaching CoreDNS about *.${BASE_DOMAIN}"
updated="$(BASE_DOMAIN="${BASE_DOMAIN}" python3 -I "${ROOT_DIR}/scripts/coredns_rewrite.py" <<<"${current}")"

kc -n kube-system create configmap coredns --from-literal=Corefile="${updated}" \
  --dry-run=client -o yaml | kc -n kube-system patch configmap coredns --patch-file=/dev/stdin >/dev/null

kc -n kube-system rollout restart deployment/coredns >/dev/null
kc -n kube-system rollout status deployment/coredns --timeout=3m >/dev/null
ok "CoreDNS resolves *.${BASE_DOMAIN} to ingress-nginx"
