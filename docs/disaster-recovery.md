# Disaster recovery

Two independent backup paths, because they fail differently.

| Path | Covers | Does not cover | Where |
|---|---|---|---|
| **Velero** | Kubernetes resources and PVC contents | etcd itself, cluster PKI | `velero` bucket |
| **etcd snapshots** | the entire datastore | PVC contents | `etcd` bucket |

`make restore-drill` exercises the Velero path for real: it creates a canary
namespace, backs it up, destroys it, restores it, and verifies the data. Run it
after changing anything about storage, Velero, or the object store. An untested
backup is not a backup.

## Scenario: someone deleted a namespace

```bash
kubectl -n velero get backups                       # find a backup from before
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata: { name: oops-restore, namespace: velero }
spec:
  backupName: velero-daily-20261105020000
  includedNamespaces: ["the-namespace"]
EOF
kubectl -n velero get restore oops-restore -w
```

Schedules: `velero-daily` (02:00, 7-day retention, all tenant namespaces) and
`velero-hourly-platform` (:30, 48h, `identity` / `argocd` / `apps`).

## Scenario: etcd is corrupted but the machine is fine

Snapshots land in the `etcd` bucket every 6 hours. To list them:

```bash
kubectl -n storage exec object-store-0 -- sh -c \
  'printf "fs.ls /buckets/etcd\n" | weed shell -master=localhost:9333 -filer=localhost:8888'
```

Restoring etcd in place on a 3-node control plane is genuinely fiddly — you
must stop all three API servers, restore the snapshot on each member with a
matching `--initial-cluster`, and restart. On a local cluster the honest
answer is usually faster:

```bash
make clean && make all          # rebuild from code (~15 min)
# then restore workloads from the most recent Velero backup
```

That works because everything except your data is in this repo. The etcd
snapshots exist for the case where you need to recover something that only
lived in etcd — an object nobody backed up — and can be inspected offline with
`etcdutl snapshot restore` into a scratch directory.

## Scenario: the whole machine is gone

This is the limit of a single-host cluster, and no amount of configuration
changes it. What survives is:

- this repository (the entire platform definition)
- `.secrets/` **if you copied it somewhere** — it is gitignored on purpose

`.secrets/` holds the root CA key, the etcd encryption key, and every generated
password. Without the etcd encryption key, existing Secrets in a restored etcd
snapshot are unreadable. Without the CA key, every issued certificate has to be
regenerated and re-trusted.

If you care about the cluster surviving the laptop, copy `.secrets/` to a
password manager or an encrypted volume. Nothing in the platform can do that
for you.

## What is deliberately not covered

- **Sealed Secrets controller key.** Lives in `kube-system`, included in the
  Velero daily backup. Lose it and every `SealedSecret` is undecryptable —
  the sealed YAML in git is useless without it.
- **Object store contents are the backup target, not backed up themselves.**
  SeaweedFS runs as a single replica on a local-path volume. If that volume
  dies you lose the backups *and* the logs and traces together. On one host
  there is nowhere else to put them; on a real cluster this is the first thing
  to move to replicated or off-site storage.
