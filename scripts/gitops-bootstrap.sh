#!/usr/bin/env bash
# Hands this repository to Argo CD.
#   make gitops-bootstrap REPO=https://github.com/you/kind-platform.git
# Optional: PATH_=gitops  REV=main  (private repos: GIT_USERNAME / GIT_TOKEN)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GITOPS_REPO="${REPO:-${GITOPS_REPO:-}}"
GITOPS_PATH="${PATH_:-${GITOPS_PATH:-gitops}}"
GITOPS_REVISION="${REV:-${GITOPS_REVISION:-HEAD}}"
[[ -n "${GITOPS_REPO}" ]] || die "set REPO=<git url>, e.g. make gitops-bootstrap REPO=https://github.com/you/repo.git"
export GITOPS_REPO GITOPS_PATH GITOPS_REVISION

if [[ -n "${GIT_TOKEN:-}" ]]; then
  log "registering repository credentials"
  kc -n argocd create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="${GITOPS_REPO}" \
    --from-literal=username="${GIT_USERNAME:-git}" \
    --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f - >/dev/null
  ok "credentials stored in argocd/gitops-repo"
fi

envsubst '${GITOPS_REPO} ${GITOPS_PATH} ${GITOPS_REVISION}' \
  < "${ROOT_DIR}/gitops/root-app.yaml" > "${BUILD_DIR}/root-app.yaml"
kc apply -f "${BUILD_DIR}/root-app.yaml"
ok "Argo CD now reconciles ${GITOPS_REPO}:${GITOPS_REVISION}/${GITOPS_PATH}/apps"
warn "child Applications under gitops/apps/ use \${GITOPS_REPO}; replace it with your repo URL before pushing"
