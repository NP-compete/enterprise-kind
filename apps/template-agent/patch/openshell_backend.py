"""An OpenShell sandbox wired in as the agent's deepagents backend.

Upstream template-agent gets every tool over MCP and keeps its files in
checkpointed graph state. This module gives it somewhere real to run
code: a long-lived OpenShell Sandbox (agents.x-k8s.io) that becomes the
default backend of the agent's `CompositeBackend`.

Nothing here defines a tool. `FilesystemMiddleware` already derives
`execute`, `read_file`, `write_file`, `edit_file`, `ls`, `glob` and
`grep` from whatever backend it is given, and `BaseSandbox` already
implements every one of those file operations on top of a single
primitive. So the only code that is ours is the part no library can
have: the three abstract members that drive a pod -- `execute()`,
`upload_files()` and `download_files()` -- plus the session lifecycle.

Making the sandbox the composite's *default* is what turns on the
`execute` tool: the middleware checks `backend.default` for
`SandboxBackendProtocol`. It also means the agent's own container
filesystem is no longer reachable through any file tool -- every path
that does not match a route lands in the sandbox instead.

The sandbox pod mounts no service account token, runs non-root with all
capabilities dropped, and is covered by a default-deny egress
NetworkPolicy (DNS only) shipped alongside this module. That policy is
ours: OpenShell's own only selects the pods its gateway manages and only
restricts Ingress, so without it these sandboxes had full outbound
network access. It is enforced because Calico is the CNI -- Kubernetes
accepts NetworkPolicy objects whether or not anything implements them.
"""

from __future__ import annotations

import base64
import json
import os
import posixpath
import shlex
import threading
import time
import uuid

from deepagents.backends.composite import CompositeBackend
from deepagents.backends.protocol import (
    BackendProtocol,
    ExecuteResponse,
    FileDownloadResponse,
    FileUploadResponse,
)
from deepagents.backends.sandbox import BaseSandbox
from langchain_core.tools import tool


# Per-command records on the agent's own stdout, which Alloy ships to Loki.
#
# The sandbox pod cannot provide these: its container runs `sleep` and
# commands are delivered over exec, whose output never reaches pod stdout.
# Querying Loki for the sandbox container returns nothing at all. If a run
# is to be visible afterwards, this side has to say so itself.
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
# A fixed sandbox reused across calls, after langchain-ai/openshell-deepagent:
# one long-lived session rather than a pod per invocation. Creating a pod cost
# ~2s on every call and threw away anything the previous command installed or
# wrote. Set SANDBOX_NAME to pin a specific one.
SESSION_NAME = os.environ.get("SANDBOX_NAME", "openshell-session")
SESSION_IDLE_TTL = int(os.environ.get("SANDBOX_IDLE_TTL", "3600"))
# Where relative paths resolve and where commands run. The image's root
# filesystem is not writable by uid 1000, so a working directory has to be
# somewhere the sandbox user owns.
WORKDIR = os.environ.get("SANDBOX_WORKDIR", "/tmp/session")
DEFAULT_TIMEOUT = int(os.environ.get("SANDBOX_EXEC_TIMEOUT", "120"))
# Where the middleware offloads large tool results and evicted messages.
# It defaults to "/", which under this topology is the sandbox -- so a
# reset would throw away conversation history the model still needs to
# rehydrate. Routed back to the agent's own (checkpointed) backend.
ARTIFACTS_ROOT = "/artifacts/"

_session_lock = threading.Lock()

GROUP, VERSION, PLURAL = "agents.x-k8s.io", "v1beta1", "sandboxes"
# One exec carries at most this much base64 in its argv. Linux caps a whole
# argv at ~2 MiB; staying well under it means a large upload is split across
# several appends rather than failing with E2BIG.
_UPLOAD_CHUNK = 256 * 1024


def _clients():
    """Import and configure the Kubernetes client lazily.

    Deferred so that importing this module never fails outside a cluster --
    the agent must still start (and report a useful error) when it has no
    Kubernetes credentials.
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
                    # The sandbox has no business talking to the API server.
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
                            "command": ["sleep", str(SESSION_IDLE_TTL)],
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


class OpenShellSandbox(BaseSandbox):
    """An OpenShell Sandbox pod driven through the Kubernetes exec API.

    `BaseSandbox` supplies every file operation on top of `execute()`, so
    only the three abstract members are implemented here. Commands run in
    `WORKDIR` inside a session pod created on first use and reused until
    `reset()`.
    """

    # The capture wrapper assumes a shell and coreutils the base class does
    # not guarantee. python:3.12-slim has both, but output already passes
    # through the exec websocket, so there is nothing to gain by capturing
    # at the source; left off.
    enable_capture_offload = False

    @property
    def id(self) -> str:
        return f"{NAMESPACE}/{SESSION_NAME}"

    # -- session -------------------------------------------------------

    def _session(self) -> tuple:
        """Return (CoreV1Api, pod name) for the shared sandbox.

        Serialised: two concurrent calls would otherwise both decide the
        sandbox is missing and race to create it, and the loser gets a
        409 AlreadyExists that surfaces to the model as a tool failure.
        """
        from kubernetes.client.rest import ApiException

        core, custom = _clients()
        with _session_lock:
            pods = core.list_namespaced_pod(
                NAMESPACE, label_selector=f"sandbox={SESSION_NAME}"
            ).items
            running = [p for p in pods if p.status.phase == "Running"]
            if running:
                return core, running[0].metadata.name

            # Clear a dead sandbox before recreating, or the name collides.
            try:
                custom.get_namespaced_custom_object(
                    GROUP, VERSION, NAMESPACE, PLURAL, SESSION_NAME
                )
                custom.delete_namespaced_custom_object(
                    GROUP, VERSION, NAMESPACE, PLURAL, SESSION_NAME
                )
                for _ in range(30):
                    if not core.list_namespaced_pod(
                        NAMESPACE, label_selector=f"sandbox={SESSION_NAME}"
                    ).items:
                        break
                    time.sleep(2)
            except ApiException as exc:
                if exc.status != 404:
                    raise

            _emit("openshell_session_create", session=SESSION_NAME)
            custom.create_namespaced_custom_object(
                GROUP, VERSION, NAMESPACE, PLURAL, _manifest(SESSION_NAME)
            )
            pod = _wait_for_pod(core, SESSION_NAME)

        self._raw(core, pod, ["/bin/sh", "-c", f"mkdir -p {shlex.quote(WORKDIR)}"], 30)
        return core, pod

    def reset(self) -> str:
        """Delete the session pod; the next command creates a fresh one."""
        from kubernetes.client.rest import ApiException

        _, custom = _clients()
        with _session_lock:
            try:
                custom.delete_namespaced_custom_object(
                    GROUP, VERSION, NAMESPACE, PLURAL, SESSION_NAME)
            except ApiException as exc:
                if exc.status != 404:
                    raise
        _emit("openshell_session_reset", session=SESSION_NAME)
        return "sandbox destroyed; the next command will start a fresh one"

    # -- the exec primitive --------------------------------------------

    @staticmethod
    def _raw(core, pod: str, argv: list[str], timeout_s: int) -> tuple[str, str, int | None]:
        """Run argv in the session pod, returning (stdout, stderr, exit code).

        The exit code arrives on the websocket's error channel as a status
        object once the process ends; there is no other way to see it, and
        `BaseSandbox` relies on it to tell a failed command from one that
        legitimately printed nothing.
        """
        from kubernetes import stream
        from kubernetes.stream.ws_client import ERROR_CHANNEL

        resp = stream.stream(
            core.connect_get_namespaced_pod_exec, pod, NAMESPACE,
            command=argv, container="openshell",
            stderr=True, stdout=True, stdin=False, tty=False,
            _preload_content=False,
        )
        out: list[str] = []
        err: list[str] = []
        deadline = time.time() + timeout_s
        timed_out = False
        while resp.is_open():
            if time.time() > deadline:
                timed_out = True
                break
            resp.update(timeout=1)
            if resp.peek_stdout():
                out.append(resp.read_stdout())
            if resp.peek_stderr():
                err.append(resp.read_stderr())

        exit_code: int | None = None
        if timed_out:
            err.append(f"\n[timed out after {timeout_s}s]")
            exit_code = 124
        else:
            try:
                status = json.loads(resp.read_channel(ERROR_CHANNEL) or "{}")
            except (ValueError, TypeError):
                status = {}
            if status.get("status") == "Success":
                exit_code = 0
            else:
                for cause in (status.get("details") or {}).get("causes") or []:
                    if cause.get("reason") == "ExitCode":
                        try:
                            exit_code = int(cause.get("message"))
                        except (TypeError, ValueError):
                            exit_code = None
        resp.close()
        return "".join(out), "".join(err), exit_code

    def execute(self, command: str, *, timeout: int | None = None) -> ExecuteResponse:
        """Run a shell command in the sandbox's working directory.

        Every sandbox command passes through here, including the ones the
        base class generates for `read_file`, `grep` and the rest, so this
        is the one place a run can be recorded.

        Args:
            command: Full shell command string.
            timeout: Seconds to allow. Defaults to SANDBOX_EXEC_TIMEOUT.

        Returns:
            `ExecuteResponse` with combined stdout and stderr.
        """
        timeout_s = max(1, min(int(timeout or DEFAULT_TIMEOUT), 600))
        run_id = uuid.uuid4().hex[:8]
        started = time.time()
        _emit("openshell_run_started", run_id=run_id, session=SESSION_NAME,
              timeout_s=timeout_s, command_bytes=len(command),
              command_preview=command[:400])
        try:
            core, pod = self._session()
            argv = ["/bin/sh", "-c",
                    f"cd {shlex.quote(WORKDIR)} 2>/dev/null || cd /tmp\n{command}"]
            out, err, code = self._raw(core, pod, argv, timeout_s)
        except Exception as exc:
            _emit("openshell_run_finished", run_id=run_id, session=SESSION_NAME,
                  status="error", duration_s=round(time.time() - started, 3),
                  error=f"{type(exc).__name__}: {exc}")
            raise
        # stdout first and stderr only when it is non-empty: the base class
        # parses the stdout of its own helper scripts as JSON, and anything
        # prepended or interleaved would make a successful read look like a
        # malformed server response.
        body = out + (("\n" + err) if err.strip() else "")
        truncated = len(body) > MAX_OUTPUT
        if truncated:
            body = f"{body[:MAX_OUTPUT]}\n...[truncated, {len(body) - MAX_OUTPUT} more bytes]"
        _emit("openshell_run_finished", run_id=run_id, session=SESSION_NAME,
              status="ok" if code == 0 else "error", exit_code=code,
              duration_s=round(time.time() - started, 3),
              output_preview=body[:800])
        return ExecuteResponse(output=body, exit_code=code, truncated=truncated)

    # -- file transfer -------------------------------------------------

    def upload_files(self, files: list[tuple[str, bytes]]) -> list[FileUploadResponse]:
        """Write files into the sandbox, creating parent directories.

        Content travels as base64 in the command line rather than over the
        exec stdin channel: closing that channel to signal EOF also tears
        down the websocket, which races the receiving process. Appending
        bounded chunks has no such race.
        """
        responses: list[FileUploadResponse] = []
        for path, content in files:
            target = _abs(path)
            try:
                blob = base64.b64encode(content).decode("ascii")
                staged = f"{target}.upload.{uuid.uuid4().hex[:8]}"
                q, s = shlex.quote(target), shlex.quote(staged)
                script = [f"mkdir -p {shlex.quote(posixpath.dirname(target) or '/')}", f": > {s}"]
                for i in range(0, len(blob), _UPLOAD_CHUNK):
                    script.append(f"printf %s '{blob[i:i + _UPLOAD_CHUNK]}' >> {s}")
                script.append(f"base64 -d {s} > {q}")
                script.append(f"rm -f {s}")
                result = self.execute("\n".join(script))
                responses.append(
                    FileUploadResponse(path=path)
                    if result.exit_code == 0
                    else FileUploadResponse(path=path, error=_file_error(result.output))
                )
            except Exception as exc:  # noqa: BLE001 - partial success is the contract
                responses.append(FileUploadResponse(path=path, error=f"{type(exc).__name__}: {exc}"))
        return responses

    def download_files(self, paths: list[str]) -> list[FileDownloadResponse]:
        """Read files out of the sandbox as bytes."""
        responses: list[FileDownloadResponse] = []
        for path in paths:
            target = _abs(path)
            try:
                result = self.execute(f"base64 < {shlex.quote(target)}")
                if result.exit_code != 0 or result.truncated:
                    detail = "file too large to download" if result.truncated else result.output
                    responses.append(FileDownloadResponse(path=path, error=_file_error(detail)))
                    continue
                responses.append(
                    FileDownloadResponse(path=path, content=base64.b64decode(result.output))
                )
            except Exception as exc:  # noqa: BLE001 - partial success is the contract
                responses.append(FileDownloadResponse(path=path, error=f"{type(exc).__name__}: {exc}"))
        return responses


def _file_error(detail: str) -> str:
    """Map a shell failure onto the standard FileOperationError codes."""
    low = (detail or "").lower()
    if "no such file" in low:
        return "file_not_found"
    if "permission denied" in low or "read-only file system" in low:
        return "permission_denied"
    if "is a directory" in low:
        return "is_directory"
    return (detail or "unknown error").strip()[:200]


def _abs(path: str) -> str:
    """Resolve a path the model supplied against the sandbox working dir."""
    path = (path or ".").strip()
    return path if posixpath.isabs(path) else posixpath.normpath(posixpath.join(WORKDIR, path))


_sandbox: OpenShellSandbox | None = None


def get_sandbox() -> OpenShellSandbox:
    """The process-wide sandbox backend."""
    global _sandbox
    if _sandbox is None:
        _sandbox = OpenShellSandbox()
    return _sandbox


def wrap_backend(backend: BackendProtocol) -> BackendProtocol:
    """Put the sandbox underneath the agent's configured routes.

    The agent's own `get_configured_backend()` builds a `CompositeBackend`
    from agent.yaml: /skills/ and /data/ read-only, /memories/ and
    /reports/ in the LangGraph store, everything else in checkpointed
    state. Only that last part changes here -- the sandbox takes over as
    the default, which is both where loose paths go and what the
    middleware inspects to decide whether to offer the `execute` tool.

    The displaced backend is kept, routed at `ARTIFACTS_ROOT`, so the
    middleware's offloaded tool results and evicted messages stay in
    checkpointed state rather than in a pod that `reset()` can delete.
    """
    sandbox = get_sandbox()
    if isinstance(backend, CompositeBackend):
        routes = dict(backend.routes)
        displaced = backend.default
    else:
        routes, displaced = {}, backend
    routes.setdefault(ARTIFACTS_ROOT, displaced)
    return CompositeBackend(default=sandbox, routes=routes, artifacts_root=ARTIFACTS_ROOT)


@tool
def openshell_reset_sandbox() -> str:
    """Destroy the sandbox so the next command starts from a clean one.

    Use when previous state is getting in the way, or to discard anything
    an earlier command left behind. Files, installed packages and the
    working directory all go.
    """
    try:
        return get_sandbox().reset()
    except Exception as exc:  # noqa: BLE001
        return f"error: {type(exc).__name__}: {exc}"


def get_builtin_tools() -> list:
    """The one tool the filesystem middleware does not already provide.

    Everything else the model needs -- execute, read_file, write_file,
    edit_file, ls, glob, grep -- `FilesystemMiddleware` derives from the
    backend itself. Recreating the pod is not a filesystem operation, so
    it has no equivalent there.
    """
    return [openshell_reset_sandbox]
