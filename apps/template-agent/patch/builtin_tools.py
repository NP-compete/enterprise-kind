"""Built-in agent tools that run inside the agent process.

Upstream template-agent gets every tool over MCP. This module adds tools
that live in the agent itself, assembled alongside the MCP ones in
deep_agent/aegra/graph.py.

openshell_run_code executes a snippet inside a disposable OpenShell
Sandbox (agents.x-k8s.io). One sandbox per call, deleted afterwards, so
nothing persists between invocations and nothing the model writes to disk
survives. The pod mounts no service account token, runs non-root with all
capabilities dropped, and is covered by a default-deny egress
NetworkPolicy (DNS only) shipped alongside this tool.

That policy is ours: OpenShell's own only selects the pods its gateway
manages and only restricts Ingress, so without it these sandboxes had
full outbound network access. It is enforced because Calico is the CNI --
Kubernetes accepts NetworkPolicy objects whether or not anything
implements them.
"""

from __future__ import annotations

import json
import os
import time
import uuid

from langchain_core.tools import tool

# Per-run records on the agent's own stdout, which Alloy ships to Loki.
#
# The sandbox pod cannot provide these: its container runs `sleep` and the
# snippet is delivered over exec, whose output never reaches pod stdout --
# and the pod is deleted seconds later anyway. Querying Loki for the
# sandbox container returns nothing at all. If a run is to be visible
# afterwards, the tool has to say so itself.
def _emit(event: str, **fields) -> None:
    """One JSON line per run event, keyed by run_id so runs stay separable.

    Written straight to stdout rather than through `logging`: the agent
    configures the root logger at WARNING with no handlers attached, so a
    logger.info() here is silently discarded and never reaches Loki. The
    agent's own records are JSON on stdout too, so the shape matches.
    """
    try:
        print(json.dumps({"event": event, "logger": "openshell.run",
                          "level": "info", **fields}), flush=True)
    except Exception:  # noqa: BLE001 - logging must never break a run
        pass

NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "template-agent")
IMAGE = os.environ.get("SANDBOX_IMAGE", "docker.io/library/python:3.12-slim")
READY_TIMEOUT = int(os.environ.get("SANDBOX_READY_TIMEOUT", "120"))
MAX_OUTPUT = int(os.environ.get("SANDBOX_MAX_OUTPUT", "16000"))
SANDBOX_HOSTNAME = os.environ.get("SANDBOX_HOSTNAME", "openshell-sandbox")

GROUP, VERSION, PLURAL = "agents.x-k8s.io", "v1beta1", "sandboxes"
INTERPRETERS = {
    "python": ["python3", "-c"],
    "bash": ["/bin/sh", "-c"],
    "sh": ["/bin/sh", "-c"],
}


def _clients():
    """Import and configure the Kubernetes client lazily.

    Deferred so that importing this module never fails outside a cluster --
    the agent must still start (and report a useful error from the tool)
    when it has no Kubernetes credentials.
    """
    from kubernetes import client, config

    try:
        config.load_incluster_config()
    except Exception:  # noqa: BLE001
        config.load_kube_config()
    return client.CoreV1Api(), client.CustomObjectsApi()


def _manifest(name: str) -> dict:
    return {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "Sandbox",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "labels": {"app.kubernetes.io/name": "agent-code-sandbox", "sandbox": name},
        },
        "spec": {
            "podTemplate": {
                # Both labels on the POD, not just the Sandbox: the
                # default-deny NetworkPolicy selects
                # app.kubernetes.io/name=agent-code-sandbox, and a label
                # present only on the parent CR selects nothing.
                "metadata": {
                    "labels": {
                        "sandbox": name,
                        "app.kubernetes.io/name": "agent-code-sandbox",
                    }
                },
                "spec": {
                    # The snippet has no business talking to the API server.
                    "automountServiceAccountToken": False,
                    "restartPolicy": "Never",
                    # Without this the hostname is the generated pod name
                    # (agent-code-<hex>), which is what the model reports
                    # back when asked. A stable name is both meaningful and
                    # stops a random id leaking into the conversation.
                    "hostname": SANDBOX_HOSTNAME,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 1000,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            # Named `openshell`, not a generic `sandbox`, so
                            # `kubectl logs -c openshell` and exec target
                            # something identifiable.
                            "name": "openshell",
                            "image": IMAGE,
                            "command": ["sleep", "3600"],
                            # Kyverno enforces requests in this namespace.
                            "resources": {
                                "requests": {"cpu": "50m", "memory": "128Mi"},
                                "limits": {"cpu": "1", "memory": "512Mi"},
                            },
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                            },
                        }
                    ],
                },
            }
        },
    }


def _wait_for_pod(core, name: str) -> str:
    deadline = time.time() + READY_TIMEOUT
    last = "no pod created yet"
    while time.time() < deadline:
        pods = core.list_namespaced_pod(NAMESPACE, label_selector=f"sandbox={name}").items
        if pods:
            pod = pods[0]
            phase = pod.status.phase
            if phase == "Running":
                return pod.metadata.name
            if phase in ("Failed", "Succeeded"):
                raise RuntimeError(f"sandbox pod ended as {phase} before it could run")
            last = f"pod is {phase}"
        time.sleep(2)
    raise TimeoutError(f"sandbox not ready within {READY_TIMEOUT}s ({last})")


def _truncate(text: str) -> str:
    if len(text) <= MAX_OUTPUT:
        return text
    return f"{text[:MAX_OUTPUT]}\n...[truncated, {len(text) - MAX_OUTPUT} more bytes]"


@tool
def openshell_run_code(code: str, language: str = "python", timeout_s: int = 60) -> str:
    """Execute code in a disposable OpenShell sandbox and return its output.

    Use this to run calculations, transform data, or test a snippet. The
    sandbox is created for this call and destroyed afterwards: nothing
    persists between calls, there is no network access beyond what policy
    allows, and no cluster credentials are available to the code.

    Args:
        code: Source to execute.
        language: One of "python", "bash", "sh". Defaults to "python".
        timeout_s: Seconds to allow execution, 1-300. Defaults to 60.

    Returns:
        The combined stdout and stderr of the snippet.
    """
    lang = (language or "python").lower().strip()
    if lang not in INTERPRETERS:
        return f"error: unsupported language {language!r}; use one of {sorted(INTERPRETERS)}"
    if not (code or "").strip():
        return "error: no code supplied"
    timeout_s = max(1, min(int(timeout_s or 60), 300))

    from kubernetes import stream
    from kubernetes.client.rest import ApiException

    try:
        core, custom = _clients()
    except Exception as exc:  # noqa: BLE001
        return f"error: no Kubernetes access from the agent ({type(exc).__name__}: {exc})"

    name = f"agent-code-{uuid.uuid4().hex[:8]}"
    started = time.time()
    _emit("openshell_run_started", run_id=name, language=lang,
          timeout_s=timeout_s, code_bytes=len(code),
          code_preview=code[:400])
    created = False
    try:
        custom.create_namespaced_custom_object(GROUP, VERSION, NAMESPACE, PLURAL, _manifest(name))
        created = True
        pod = _wait_for_pod(core, name)

        resp = stream.stream(
            core.connect_get_namespaced_pod_exec,
            pod,
            NAMESPACE,
            command=INTERPRETERS[lang] + [code],
            container="openshell",
            stderr=True,
            stdout=True,
            stdin=False,
            tty=False,
            _preload_content=False,
        )
        out: list[str] = []
        err: list[str] = []
        deadline = time.time() + timeout_s
        timed_out = False
        while resp.is_open():
            if time.time() > deadline:
                timed_out = True
                resp.close()
                break
            resp.update(timeout=1)
            if resp.peek_stdout():
                out.append(resp.read_stdout())
            if resp.peek_stderr():
                err.append(resp.read_stderr())
        if not timed_out:
            resp.close()

        body = "".join(out)
        if err:
            body += "\n--- stderr ---\n" + "".join(err)
        if timed_out:
            body += f"\n[timed out after {timeout_s}s]"
        _emit("openshell_run_finished", run_id=name, language=lang,
              status="timeout" if timed_out else "ok",
              duration_s=round(time.time() - started, 3),
              stdout_bytes=len("".join(out)), stderr_bytes=len("".join(err)),
              output_preview=_truncate(body)[:800])
        return _truncate(body) or "(no output)"

    except ApiException as exc:
        _emit("openshell_run_finished", run_id=name, language=lang,
              status="error", duration_s=round(time.time() - started, 3),
              error=f"kubernetes API {exc.status} {exc.reason}")
        return f"error: kubernetes API {exc.status} {exc.reason}"
    except Exception as exc:  # noqa: BLE001 - returned to the model, not swallowed
        _emit("openshell_run_finished", run_id=name, language=lang,
              status="error", duration_s=round(time.time() - started, 3),
              error=f"{type(exc).__name__}: {exc}")
        return f"error: {type(exc).__name__}: {exc}"
    finally:
        if created:
            try:
                custom.delete_namespaced_custom_object(GROUP, VERSION, NAMESPACE, PLURAL, name)
            except Exception:  # noqa: BLE001 - best effort cleanup
                pass


def get_builtin_tools() -> list:
    """Tools assembled into the agent alongside the MCP ones."""
    return [openshell_run_code]
