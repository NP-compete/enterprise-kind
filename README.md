# kind production platform

A local Kubernetes platform built to production practice: HA control plane,
encrypted secrets, enforced network and admission policy, single sign-on,
observability, and backups that are tested rather than assumed.

Everything is in this folder. `make clean && make all` rebuilds it from nothing.

```
make all             # cluster + platform + verification   (~20 min cold)
make urls            # consoles and credentials
make smoke           # 56 end-to-end checks
make restore-drill   # destroy a namespace and restore it, for real
make clean           # delete everything
```

First run also needs two commands that require your password, so they are not
run for you:

```
make hosts      # maps *.kind.test to 127.0.0.1 in /etc/hosts
make trust-ca   # trusts the cluster CA so browsers stop warning
```

## Consoles

Start at **https://home.kind.test** — it links everything and shows live health.

| URL | What |
|---|---|
| `home.kind.test` | Landing page with cluster stats |
| `headlamp.kind.test` | Cluster management UI |
| `argocd.kind.test` | GitOps |
| `grafana.kind.test` | Metrics, logs, traces, 31 dashboards |
| `prometheus.kind.test` · `alertmanager.kind.test` | Raw PromQL, alert routing |
| `keycloak.kind.test` | Identity provider |
| `registry.kind.test` | Image registry UI |
| `flows.kind.test` | Live pod-to-pod network flows |

Every one is behind Keycloak SSO. Sign in with **`soham` / `soham`** (change it
in `config.env`). Group membership decides access: `platform-admins` gets admin
everywhere, `platform-viewers` read-only.

## What makes it production-shaped

**Control plane** — 3 nodes with real etcd quorum, so losing one survives.
Secrets are encrypted at rest with AES-CBC; the smoke suite writes a canary
Secret and greps raw etcd to prove the plaintext is absent. API audit logging
is on and the audit trail is queryable in Grafana.

**Identity** — Keycloak with a realm defined in git. Every console uses OIDC,
and the API server itself trusts it, so a Headlamp login becomes a real
Kubernetes identity (`oidc:soham` in group `oidc:platform-admins`) governed by
RBAC. Prometheus and Alertmanager, which have no login of their own, sit behind
oauth2-proxy.

**Networking** — Calico enforces NetworkPolicy. The tenant template's
default-deny rules actually deny: the smoke suite connects pod-to-pod, applies
the policy, and confirms the connection then times out.

**Policy** — Kyverno enforces (not audits) resource requests, no `:latest`
tags, hardened security contexts, and no workloads in `default`. Platform
namespaces are excluded by label, so new components are covered automatically.

**Durability** — S3-compatible object storage holds Loki chunks, Tempo traces
and Velero backups, so observability data outlives the node it ran on. Velero
runs daily and hourly schedules; etcd snapshots every 6 hours into a separate
bucket. `make restore-drill` proves the whole path.

**Supply chain** — The registry is TLS-only with authentication; anonymous pulls
get `401`. Sealed Secrets lets secrets be committed to git in encrypted form.

## Layout

```
config.env                every tunable: ports, domain, versions, credentials
Makefile                  the only interface you need
cluster/                  node topology, audit policy, admission + OIDC config
platform/values/          one values file per helm release
platform/manifests/       namespaces, policies, portal, backups, object store
platform/dashboards/      custom Grafana dashboards
apps/podinfo/             reference workload (not deployed; `make demo`)
gitops/                   Argo CD app-of-apps
scripts/                  what the Makefile calls
docs/disaster-recovery.md restore procedures and their limits
.secrets/                 generated keys and passwords (gitignored)
```

## Operating it

```bash
make push IMG=myapp:1.0          # build into the registry (logs in for you)
make seal < secret.yaml          # encrypt a Secret for git
make token                       # Headlamp token, if SSO is broken
make break-glass                 # re-enable local logins if Keycloak is down
make status                      # health summary
```

Platform namespaces are labelled `platform.kind.local/component`. That label
drives policy exclusions and CA distribution — remove it from a namespace and
that namespace starts being policed as a tenant.

## Known limits

These are real and mostly not fixable on one machine.

- **One physical host.** Three control planes give you etcd quorum and survive
  a node container dying, but not the Mac dying. Everything stops together.
- **Storage is not replicated.** The object store is a single replica on a
  local-path volume, and it holds backups *and* logs *and* traces. If that
  volume dies they go together.
- **`.secrets/` is unrecoverable if lost.** It holds the CA key, the etcd
  encryption key and every password. Copy it somewhere encrypted — see
  `docs/disaster-recovery.md`.
- **Memory is the binding constraint.** The podman VM OOM-killed every node
  twice during development. PriorityClasses now control eviction order, but if
  you add much more, raise the VM's allocation.
- **No image signature verification.** cosign + Kyverno `ImageVerify` was
  planned and is not done; the registry authenticates but does not attest.
- **GitOps is not bootstrapped.** Argo CD is installed and ready; point it at a
  repo with `make gitops-bootstrap REPO=...`.
- **Cilium is impossible here.** Its datapath needs a BPF filesystem, which
  rootless podman cannot mount. Calico gives equivalent policy enforcement;
  Hubble's flow UI is replaced by Calico Whisker at `flows.kind.test`.
- **`require-probes` and `require-ownership-labels` stay in Audit**, because
  enforcing them would reject upstream charts we do not control.

## Requirements

macOS with podman (or Docker via `CONTAINER_ENGINE=docker`), kind, kubectl,
helm, jq, openssl, envsubst. The podman VM wants ≥6 CPU and ≥12 GiB; preflight
checks and warns. It also sets two sysctls *inside the VM* — unprivileged port
binding and kernel keyring limits — both needed for kind under rootless podman.
