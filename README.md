# kind production platform

A local Kubernetes platform built to production practice: encrypted secrets,
enforced network and admission policy, single sign-on, observability, and
backups that are tested rather than assumed -- fitted into about 8 GiB.

It is deliberately **not** highly available. One control plane, one worker,
one replica of everything. The practices are production-shaped; the
redundancy is not, and the trade is stated plainly under *Known limits*.

Everything is in this folder. `make clean && make all` rebuilds it from nothing.

```
make all             # everything: cluster, platform, host wiring, verification
make doctor          # something broken? names the problem and prints the fix
make urls            # consoles and the logins you need
make secrets         # every generated credential
make smoke           # 80 end-to-end checks
make clean           # delete the cluster, keep .secrets/
make reset           # delete everything including .secrets/
```

`make all` asks for your password once at the start — it needs sudo for
`/etc/hosts` and the macOS keychain, and asking up front beats a prompt
appearing fifteen minutes in. Unattended, use `make up && make install &&
make smoke` and skip the host wiring.

Everything is idempotent. If a step fails, re-run the same command; it
resumes rather than starting over, and tells you so.

## Consoles

Start at **https://home.kind.test** — it links everything and shows live health.

| URL | What |
|---|---|
| `home.kind.test` | Landing page with cluster stats |
| `headlamp.kind.test` | Cluster management UI |
| `argocd.kind.test` | GitOps |
| `grafana.kind.test` | Metrics, logs, traces and dashboards |
| `prometheus.kind.test` · `alertmanager.kind.test` | Raw PromQL, alert routing |
| `keycloak.kind.test` | Identity provider |
| `registry.kind.test` | Image registry UI |
| `flows.kind.test` | Live pod-to-pod network flows |

Every one is behind Keycloak SSO. Passwords are generated on first install and
printed by `make urls` — nothing in this repo ships a default credential. Pin
one explicitly in `config.env` if you would rather have a memorable password
than a secret one. Group membership decides access: `platform-admins` gets
admin everywhere, `platform-viewers` read-only.

## What makes it production-shaped

**It runs in 9.7 GiB, measured.** An earlier revision was fully HA — 3
control planes, 3 workers, two or three replicas of everything — and took
22 GiB across 162 pods. This one is 61 pods. Both numbers are the sum of
`kubectl top nodes`, taken on an idle cluster after `make smoke`.

| | HA | now |
|---|---|---|
| kube-apiserver | 5.9 GiB (3 nodes) | 2.0 GiB (1 node) |
| Prometheus | 2.3 GiB (×2, 15d, 30s) | 0.4 GiB (×1, 2d, 60s) |
| Keycloak | 1.2 GiB (×2) | 0.4 GiB (×1, 384 MiB heap) |
| Loki | 1.0 GiB (SimpleScalable, 7 pods) | 0.3 GiB (SingleBinary) |
| MetalLB | 0.65 GiB (14 pods) | removed |
| **total pod RSS** | **18.8 GiB** | **7.5 GiB** |
| **cluster total** | **~22 GiB** | **9.7 GiB** |

The apiserver was 31% of all pod memory and nothing in the config hints at
it: each instance keeps a watch cache over every object and every CRD, and
this platform installs a lot of CRDs. **Collapsing the control plane to one
node saved more than every replica reduction put together** — worth knowing
before spending a day tuning replica counts.

Everything is single-replica, so every PodDisruptionBudget is
`maxUnavailable: 1`. A `minAvailable: 1` budget over a one-pod Deployment can
never be satisfied during an eviction and leaves the node undrainable;
`make smoke` asserts none have crept back in.

**Control plane** — 1 node, so no etcd quorum and no tolerance for losing it.
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

**Durability** — S3-compatible object storage holds Loki chunks, Tempo
traces and Velero backups, so observability data outlives the node it ran
on. Velero
runs daily and hourly schedules; etcd snapshots every 6 hours into a separate
bucket. `make restore-drill` proves the whole path.

**Supply chain** — The registry is TLS-only with authentication; anonymous pulls
get `401`. Sealed Secrets lets secrets be committed to git in encrypted form.

## Layout

```
.github/workflows/ci.yml  gates chart bumps; no cluster needed
config.env                every tunable: ports, domain, versions, credentials
Makefile                  the only interface you need
cluster/                  node topology, audit policy, admission + OIDC config
platform/values/          one values file per helm release
platform/manifests/       namespaces, policies, portal, backups, object store
platform/dashboards/      custom Grafana dashboards
apps/podinfo/             reference workload (not deployed; `make demo`)
gitops/                   Argo CD app-of-apps
scripts/                  10 files, subcommand-dispatched:
  cluster.sh              preflight|pki|authn|registry|dns|up|down
  identity.sh             keycloak|apiserver|vault
  platform-install.sh     everything on top of the cluster
  ops.sh                  urls|status|token|seal|break-glass|demo|gitops|push|sign
  verify.sh               smoke|restore|failover
  host-setup.sh           hosts|trust-ca   (the only things touching your Mac)
  lint.sh                 static checks, no cluster
  lib.sh                  shared helpers
docs/disaster-recovery.md restore procedures and their limits
.secrets/                 generated keys and passwords (gitignored)
```

## Operating it

```bash
make push IMG=myapp:1.0          # build into the registry (logs in for you)
make sign IMG=myapp:1.0          # cosign-sign it so Kyverno will admit it
make seal < secret.yaml          # encrypt a Secret for git
make token                       # Headlamp token, if SSO is broken
make break-glass                 # re-enable local logins if Keycloak is down
make status                      # health summary
make lint                        # render every chart at its pinned version
```

`make lint` is what CI runs, and it exists for one failure mode: bumping a
chart version whose values keys moved. That renders fine on the old chart and
fails at minute eighteen of a cold build on the new one. Rendering every
chart against its pin catches it in seconds.

Platform namespaces are labelled `platform.kind.local/component`. That label
drives policy exclusions and CA distribution — remove it from a namespace and
that namespace starts being policed as a tenant.

## Observability

Loki, Grafana and Tempo with Prometheus for metrics — LGT + Prometheus
rather than full LGTM. Mimir would add multi-tenant metrics scale this
cluster has no use for, at a cost of several pods; one Prometheus holding
two days of data is the right size here.

**Alloy** is the collector. It scrapes pod logs, ships Kubernetes events,
and terminates OTLP on 4317/4318, fanning out to Tempo (traces),
Prometheus (metrics) and Loki (logs). Anything that speaks OTLP only needs
pointing at `alloy.observability.svc.cluster.local:4317`.

The agent does exactly that, so its traces and metrics land in the same
place as the platform's. Two things were needed and only one is obvious:
the endpoint, and `ENABLE_OTEL=true` — the agent's master switch defaults
off, so an endpoint alone configures an exporter that never starts.

Grafana ties them together: trace→logs, trace→metrics, a service map, and
a Loki derived field that turns a `trace_id` in a log line into a link to
the trace. `make smoke` asserts data is actually arriving in all three,
not merely that the components are up.

## Sandboxed agents (OpenShell)

NVIDIA [OpenShell](https://docs.nvidia.com/openshell/kubernetes/setup) runs
agent workloads in sandboxes with a brokered network boundary: each sandbox
is a supervisor pod plus a workload pod, and the workload's egress rides
back over the supervisor's session where policy decides what is allowed out.

```bash
make openshell    # fetch the client mTLS bundle, register the CLI, port-forward
```

It is installed by `make install` along with the
[Agent Sandbox](https://github.com/kubernetes-sigs/agent-sandbox) controller
it depends on, and costs about 34 MiB.

Three things worth knowing:

- **The isolation is only real because Calico enforces NetworkPolicy.**
  Kubernetes accepts NetworkPolicy objects whether or not the CNI implements
  them, so on a cluster running kindnet the sandbox boundary would be
  decorative. `make smoke` proves enforcement with a pod-to-pod test.
- **Sandboxes are policed like tenants.** They run in `openshell-sandboxes`,
  which deliberately does *not* carry the platform exemption label every
  other platform namespace has — Kyverno applies to them in full. A smoke
  check asserts that label stays absent.
- **No ingress.** The gateway requires client certificates and an ingress
  proxy cannot present one, so access is via port-forward. Exposing it
  properly means `server.tls.enableMtls=false` plus OIDC against Keycloak.

## Known limits

These are real and mostly not fixable on one machine.

- **One physical host.** Three control planes give you etcd quorum and survive
  a node container dying, but not the Mac dying. Everything stops together.
- **Storage is not replicated, and backups share the cluster's fate.** The
  object store is a single replica on a local-path volume, and it holds
  backups *and* logs *and* traces. If that volume dies they go together. This
  is the largest remaining gap: a real platform puts the backup target
  somewhere the cluster cannot take with it.
- **`.secrets/` is unrecoverable if lost.** It holds the CA key, the etcd
  encryption key and every password. Copy it somewhere encrypted — see
  `docs/disaster-recovery.md`.
- **Memory is still the binding constraint**, just a smaller one. Budget
  **≥4 CPU and ≥12 GiB** for the podman VM; preflight checks and warns.
  Measured steady state is 9.7 GiB. It was 7.4 GiB before every
  ServiceMonitor was enabled at first install — more scrape targets cost
  about 1.4 GiB across Prometheus, Grafana and Alloy. Turning monitoring
  off for components you do not care about is the cheapest way back down.
  Note that kind nodes do not partition the VM — each advertises the whole
  machine as allocatable, so the scheduler will never refuse a pod and the
  failure mode is the OOM killer, not `Pending`.
- **Nothing is redundant.** One replica of every component, on one worker,
  against one etcd member. Any pod restart is a brief outage of that thing;
  losing the worker is a total outage. CI enforces that nothing scales back
  up, because doing so silently breaks the memory budget.
- **Dropped to fit the budget:** MetalLB (so `type: LoadBalancer` stays
  `<pending>` forever), trivy-operator (no image
  scanning), KEDA (no event-driven autoscaling), and Argo CD's redis-ha.
  Each is one commit away in git history.
- **Prometheus keeps 2 days at a 60s scrape, with cAdvisor series off.**
  Per-container metrics are gone; node and pod-level numbers still come from
  kube-state-metrics. Raise `retention` and re-enable `cAdvisor` in
  `platform/values/kube-prometheus-stack.yaml` if you need the detail, and
  budget roughly +1 GiB.
- **Keycloak runs with a hard 384 MiB heap.** Fine for interactive logins;
  a load test will hit `OutOfMemoryError` before it hits anything else.
- **GitOps is not bootstrapped.** Argo CD is installed and ready; point it at a
  repo with `make gitops-bootstrap REPO=...`.
- **Cilium is impossible here.** Its datapath needs a BPF filesystem, which
  rootless podman cannot mount. Calico gives equivalent policy enforcement;
  Hubble's flow UI is replaced by Calico Whisker at `flows.kind.test`.
- **`require-probes` and `require-ownership-labels` stay in Audit**, because
  enforcing them would reject upstream charts we do not control.

## Requirements

macOS with podman (or Docker via `CONTAINER_ENGINE=docker`), kind, kubectl,
helm, jq, openssl, envsubst. `make lint` additionally wants kubeconform and
shellcheck. The podman VM wants ≥4 CPU and ≥12 GiB; preflight
checks and warns. It also sets two sysctls *inside the VM* — unprivileged port
binding and kernel keyring limits — both needed for kind under rootless podman.
