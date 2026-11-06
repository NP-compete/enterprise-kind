#!/usr/bin/env bash
# Encrypt a Secret so it is safe to commit to git.
#
#   kubectl create secret generic my-secret --from-literal=k=v \
#     --dry-run=client -o yaml | make seal > my-sealed-secret.yaml
#
# Only this cluster's sealed-secrets controller can decrypt the result. Its
# private key lives in kube-system/sealed-secrets-key* and is covered by the
# Velero daily schedule -- lose it and sealed secrets are unrecoverable.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KUBESEAL="$(command -v kubeseal || true)"
if [[ -z "${KUBESEAL}" ]]; then
  # Vendor it rather than requiring a system install, so `make seal` just works.
  KUBESEAL="${BUILD_DIR}/bin/kubeseal"
  if [[ ! -x "${KUBESEAL}" ]]; then
    mkdir -p "${BUILD_DIR}/bin"
    case "$(uname -m)" in
      arm64|aarch64) arch=arm64 ;;
      *)             arch=amd64 ;;
    esac
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    log "fetching kubeseal ${SEALED_SECRETS_VERSION} (${os}-${arch})"
    curl -sL --fail \
      "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${SEALED_SECRETS_VERSION#v}-${os}-${arch}.tar.gz" \
      -o "${BUILD_DIR}/kubeseal.tgz" || die "could not download kubeseal"
    tar -xzf "${BUILD_DIR}/kubeseal.tgz" -C "${BUILD_DIR}/bin" kubeseal || die "could not extract kubeseal"
    chmod +x "${KUBESEAL}"
  fi
fi

exec "${KUBESEAL}" --context "${KUBECONTEXT}" \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --format yaml
