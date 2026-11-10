# OpenShell setup

How NVIDIA [OpenShell](https://docs.nvidia.com/openshell/kubernetes/setup) is
installed on this cluster, following the shape of NVIDIA's
[OpenShift guide](https://docs.nvidia.com/openshell/kubernetes/openshift):
an exposed gateway with a cert-manager server certificate and OIDC login,
rather than a port-forward with client certificates.

Everything here is applied by `make install`. Nothing needs to be run by
hand; this page says what it does and why.

| Where | What |
|---|---|
| `scripts/platform-install.sh` (openshell section) | namespaces, CA ConfigMap, helm install, ingress |
| `platform/values/openshell.yaml` | every chart value, each with its reason |
| `platform/manifests/openshell-ingress.yaml` | the pass-through Ingress |
| `platform/values/ingress-nginx.yaml` | `enable-ssl-passthrough` |
| `scripts/identity.sh` | the `openshell-cli` Keycloak client and realm roles |
| `scripts/ops.sh` (`cmd_openshell`) | `make openshell` — register the gateway, log in |
| `scripts/verify.sh` (sandboxing section) | the smoke checks |

## Prerequisites

- **A CNI that enforces NetworkPolicy.** OpenShell creates policies;
  Kubernetes does not check that anything implements them. This cluster runs
  Calico for exactly this reason, and `make smoke` proves enforcement with a
  pod-to-pod test rather than asserting the objects exist.
- **Agent Sandbox CRDs and controller**, installed first by
  `platform-install.sh` — the chart has a preflight that refuses to render
  without `agents.x-k8s.io`.
- **cert-manager with the `platform-ca` ClusterIssuer**, which the rest of
  the platform already uses.
- **Keycloak**, for user authentication.

## Namespaces

```
openshell              the gateway. Platform infrastructure, so it carries
                       platform.kind.local/component=sandboxing and is
                       excluded from tenant policy.
openshell-sandboxes    the sandboxes. Deliberately NOT exempt: these are
                       untrusted workloads and Kyverno applies in full.
                       Pod Security enforce=baseline, warn=restricted.
```

Splitting them is a choice, and it costs something: the supervisor pods run
in the sandbox namespace but mount a secret the chart only creates in the
release namespace, so the install replicates `openshell-client-tls` across.
Running both in one namespace would avoid that and lose the policing.

## TLS and exposure

The gateway terminates its own TLS and chooses a certificate by SNI:

- **internal** (`openshell-server-tls`, chart CA) for in-cluster names, which
  is what supervisors verify against;
- **external** (`openshell-server-external-tls`, platform CA) for
  `openshell.kind.test`, created because `certManager.serverIssuerRef` points
  at the `platform-ca` ClusterIssuer.

`platform/manifests/openshell-ingress.yaml` therefore uses
`nginx.ingress.kubernetes.io/ssl-passthrough: "true"`. A terminating proxy
would hide the SNI and break the certificate selection, would have to deal
with gRPC and HTTP/2 framing, and would see plaintext. Passthrough is off by
default in ingress-nginx and is enabled controller-wide; hosts without the
annotation keep using the normal terminating server.

This is the kind equivalent of the pass-through `Route` in NVIDIA's
OpenShift guide. The `openshiftRoute` and `grpcRoute` chart options are the
OpenShift and Gateway API forms of the same idea and are both off.

## Authentication

A proxy cannot present a client certificate on a user's behalf, so exposing
the gateway means moving user authentication off mTLS:

```yaml
server:
  tls:
    enableMtls: false
  oidc:
    issuer: https://keycloak.kind.test/realms/platform
    audience: openshell-cli
    rolesClaim: realm_access.roles
    adminRole: openshell-admin
    userRole: openshell-user
    caConfigMapName: platform-ca
```

Three things have to line up, and each has a failure mode that looks like
something else:

- **`openshell-cli` is a public client with PKCE.** The CLI runs on a laptop
  and cannot keep a secret. Its redirect URIs are loopback with a wildcard
  port, because the CLI picks the port at runtime (RFC 8252); the device
  flow is also enabled for a shell with no browser.
- **An audience mapper names `openshell-cli`.** Keycloak does not populate
  `aud` by default and the gateway checks it, so without the mapper every
  token is rejected as invalid.
- **`caConfigMapName: platform-ca`.** Keycloak is served from the platform
  CA, which is not in the gateway's trust store. Without it the JWKS fetch
  fails TLS verification — and the symptom is again "invalid token".

RBAC is on rather than authenticate-only: with both role names blank the
gateway treats everyone who can log in as a Platform Admin. `identity.sh`
creates the two realm roles and binds `openshell-admin` to the
`platform-admins` group and `openshell-user` to `platform-viewers`.

## Using it

```bash
make hosts        # once, so openshell.kind.test resolves
make trust-ca     # once, so the CLI trusts the gateway's certificate
make openshell    # register the gateway and log in
```

`make openshell` is equivalent to:

```bash
openshell gateway add https://openshell.kind.test --name kindprod \
  --oidc-issuer https://keycloak.kind.test/realms/platform \
  --oidc-client-id openshell-cli
openshell gateway login kindprod
openshell status
```

## Known limitation: gateway-provisioned sandboxes

The gateway runs, authenticates and reports healthy, but it **cannot start
sandboxes under rootless podman**. Both settings of
`server.enableUserNamespaces` fail, in different places:

| Setting | Failure |
|---|---|
| `false` (what we ship) | the supervisor attaches its boundary, then dies with `failed to spawn sandbox entrypoint process: Permission denied` |
| `true` | the pod sets `hostUsers: false` and the kubelet cannot create it at all: `failed to create network namespace: failed to set effective UID: invalid argument` — a user namespace cannot be nested inside the already-user-namespaced rootless podman container |

`false` is the better failure, so that is what is set.

This is a limitation of the host, not of the platform; on a cluster whose
nodes are real hosts, neither failure applies. The agent's own sandbox tool
therefore drives the Agent Sandbox CRD directly (see
`apps/template-agent/patch/openshell_backend.py`), which works because those
pods do not set `hostUsers`.

## The agent's sandbox runtimes

The agent gets one sandbox pod per language, created on first use:

| Runtime | Image | Built? |
|---|---|---|
| `python` (default) | `registry.access.redhat.com/hi/python:3.14-builder` | pulled as-is |
| `node` | `localhost/openshell-sandbox-node:22` | Hummingbird nodejs + python3 |
| `go` | `localhost/openshell-sandbox-go:1.25.10` | Hummingbird go + python3 |

All three are Red Hat [Project Hummingbird](https://hummingbird-project.io/)
images — minimal, CIS-hardened, reproducible builds. Two details decide the
shape of this:

- **The `-builder` variant, always.** Hummingbird's default variants are
  distroless: no shell, no package manager. This backend is shell-first
  (`BaseSandbox` turns every file operation into a `/bin/sh` command, and the
  pod's keepalive command is `sleep`), so a distroless image cannot even
  start the container.
- **Every runtime needs `python3`.** Not for the user's code — for
  deepagents: `read_file`, `ls`, `grep`, `glob` and `edit_file` are python
  scripts piped through the shell. Without it a runtime supports `execute`
  and nothing else, which is how `write_file` on Node first failed with
  `python3: command not found`. The pod cannot install it itself — its
  egress is DNS-only — so `make agent-stack` derives the two images at build
  time from `patch/Containerfile.sandbox` and side-loads them.

The runtime table lives in `openshell_backend.py` and `ops.sh` reads it back
out of that file, so adding a fourth runtime is one dict entry plus a
rebuild.

The model switches with `openshell_use_runtime`. Two caveats worth knowing:
each runtime is a separate pod, so **files do not cross between them**; and
the selection is process-wide rather than per-conversation, because the
filesystem middleware calls the backend with no request context. Fine for
one operator, wrong for concurrent tenants — pin `SANDBOX_RUNTIME` and drop
the tool if that ever matters.
