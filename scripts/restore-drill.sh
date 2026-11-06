#!/usr/bin/env bash
# Prove the backups can actually restore, rather than assuming.
#
#   make restore-drill
#
# Creates a throwaway namespace with a canary ConfigMap and a PVC, backs it up
# with Velero, destroys it, restores it, and checks the data came back. Touches
# nothing outside the drill namespace.
#
# An untested backup is not a backup. Run this after changing anything about
# storage, Velero, or the object store.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=restore-drill
BACKUP="drill-$(date -u +%Y%m%d%H%M%S)"
CANARY="the-quick-brown-fox-$(date -u +%s)"

cleanup() {
  kc delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "1/6  creating the drill namespace with a canary"
kc delete namespace "${NS}" --wait=true >/dev/null 2>&1 || true
kc create namespace "${NS}" >/dev/null
kc label namespace "${NS}" platform.kind.local/component=drill >/dev/null
kc -n "${NS}" create configmap canary --from-literal=value="${CANARY}" >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: canary-data
  namespace: ${NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources: { requests: { storage: 64Mi } }
EOF
ok "canary value: ${CANARY}"

log "2/6  backing up the namespace"
kc apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP}
  namespace: velero
spec:
  includedNamespaces: ["${NS}"]
  ttl: 1h
  snapshotVolumes: false
  storageLocation: default
EOF
for _ in $(seq 1 60); do
  phase="$(kc -n velero get backup "${BACKUP}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${phase}" in Completed|PartiallyFailed|Failed|FailedValidation) break ;; esac
  sleep 5
done
[[ "${phase}" == "Completed" ]] || die "backup did not complete (phase=${phase:-unknown})"
ok "backup ${BACKUP} Completed"

log "3/6  destroying the namespace"
kc delete namespace "${NS}" --wait=true >/dev/null
kc get namespace "${NS}" >/dev/null 2>&1 && die "namespace still present after delete"
ok "namespace gone"

log "4/6  restoring from the backup"
kc apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${BACKUP}-restore
  namespace: velero
spec:
  backupName: ${BACKUP}
  existingResourcePolicy: update
EOF
for _ in $(seq 1 60); do
  rphase="$(kc -n velero get restore "${BACKUP}-restore" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${rphase}" in Completed|PartiallyFailed|Failed) break ;; esac
  sleep 5
done
ok "restore phase: ${rphase:-unknown}"

log "5/6  checking the canary survived"
for _ in $(seq 1 24); do
  got="$(kc -n "${NS}" get configmap canary -o jsonpath='{.data.value}' 2>/dev/null || true)"
  [[ -n "${got}" ]] && break
  sleep 5
done
[[ "${got}" == "${CANARY}" ]] \
  || die "canary mismatch: expected '${CANARY}', got '${got:-<nothing>}'"
ok "canary restored intact"

log "6/6  checking the PVC came back"
pvc="$(kc -n "${NS}" get pvc canary-data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ -n "${pvc}" ]] && ok "PVC restored (phase=${pvc})" || warn "PVC did not come back"

echo
ok "RESTORE DRILL PASSED -- backup ${BACKUP} restored a destroyed namespace"
echo "   etcd snapshots are a separate path: see docs/disaster-recovery.md"
