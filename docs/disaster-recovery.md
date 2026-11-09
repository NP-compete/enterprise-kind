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

## Scenario: one node is gone

There is no recovery. This cluster is one control plane and one worker, with
one replica of everything and a single-member etcd. Losing the worker stops
every workload; losing the control plane stops the cluster. That is the
deliberate trade for fitting in ~8 GiB, and it is why the backup and restore
paths below matter more here than they would on a redundant cluster.

`make failover-drill` still exists and still works, but it refuses to run
with fewer than two workers rather than reporting a meaningless failure.
Scale `cluster/kind-config.yaml` back up and raise the replica counts in
`platform/values/` and it measures real failover again.

## Scenario: Postgres will not start

Keycloak and Grafana both keep their state in the CloudNativePG cluster, so
a Postgres that will not come up means no logins and no dashboards. With
`PG_INSTANCES=1` there is no replica to promote; the recovery is the volume.

```bash
kubectl -n identity get cluster platform-pg
kubectl -n identity logs platform-pg-1 -c postgres
```

Raising `PG_INSTANCES` to 3 in `config.env` restores automatic failover and
costs about 250 MiB — cheap, and the first thing to turn back on if this
cluster ever gets a memory budget again.

## Scenario: Vault restarts

Vault comes up **sealed** after any restart, including an ordinary pod
reschedule. Re-run:

```bash
./scripts/identity.sh vault
```

It is idempotent and unseals from `.secrets/vault-unseal-keys.json`. It
derives the node count from the StatefulSet, so it works unchanged whether
Vault is standalone or a Raft cluster.

**One trap worth knowing:** `.secrets/` survives `make clean`, so a rebuilt
cluster finds `vault-installer-role-id` and `-secret-id` belonging to the
*previous* Vault. `vault-init.sh` verifies those credentials with a real
login before relying on them and will not revoke the root token until a
working replacement is proven. If you still see "installer AppRole login
failed", wipe Vault's storage:

```bash
kubectl -n vault delete statefulset vault --cascade=foreground
kubectl -n vault delete pvc -l app.kubernetes.io/name=vault
rm -f .secrets/vault-unseal-keys.json .secrets/vault-installer-* .secrets/avp-*
make install
```

## Scenario: a rolling update is stuck

A StatefulSet `RollingUpdate` will not replace a pod that never becomes
Ready, so a bad change — a wrong JVM flag, a missing secret — leaves the old
pod crashlooping with the old spec while `helm upgrade --wait` times out.
The spec on the StatefulSet is already correct; only the pod is stale.

```bash
kubectl -n <ns> delete pod <name>-0
```

Deployments have the same shape with required pod anti-affinity: the old
pod's rule blocks the new pod from the only node, so the rollout stalls at
`Pending` with "didn't satisfy existing pods anti-affinity rules". Delete
the old ReplicaSet rather than waiting.

## What is deliberately not covered

- **Sealed Secrets controller key.** Lives in `kube-system`, included in the
  Velero daily backup. Lose it and every `SealedSecret` is undecryptable —
  the sealed YAML in git is useless without it.
- **Object store contents are the backup target, not backed up themselves.**
  SeaweedFS runs as a single replica on a local-path volume. If that volume
  dies you lose the backups *and* the logs together. On one host
  there is nowhere else to put them; on a real cluster this is the first thing
  to move to replicated or off-site storage.
