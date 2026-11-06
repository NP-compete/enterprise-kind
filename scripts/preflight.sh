#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "preflight"
for t in kind kubectl helm "${CE}" envsubst; do need "$t"; done

"${CE}" info >/dev/null 2>&1 || die "${CE} is not responding. For podman: podman machine start"

if [[ "${CE}" == "podman" ]]; then
  cpus=$(podman machine inspect --format '{{.Resources.CPUs}}' 2>/dev/null | head -1 || echo 0)
  mem=$(podman machine inspect --format '{{.Resources.Memory}}'  2>/dev/null | head -1 || echo 0)
  [[ "${cpus:-0}" -ge 6    ]] || warn "podman machine has ${cpus} CPUs; >=6 recommended for the full platform"
  [[ "${mem:-0}"  -ge 12288 ]] || warn "podman machine has ${mem}MiB RAM; >=12288 recommended"
  ok "podman machine: ${cpus} cpu / ${mem} MiB"

  # Rootless podman cannot publish ports < 1024 unless the VM kernel allows it.
  # The sysctl lives inside the podman VM, not on macOS, so this is safe to set.
  lowest=$(printf '%s\n' "${HTTP_PORT}" "${HTTPS_PORT}" | sort -n | head -1)
  if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" && "${lowest}" -lt 1024 ]]; then
    current=$(podman machine ssh 'cat /proc/sys/net/ipv4/ip_unprivileged_port_start' 2>/dev/null || echo 1024)
    if [[ "${current}" -gt "${lowest}" ]]; then
      log "allowing unprivileged ports >= ${lowest} inside the podman VM"
      podman machine ssh "sudo sh -c 'echo net.ipv4.ip_unprivileged_port_start=${lowest} > /etc/sysctl.d/99-kind-ports.conf && sysctl -w net.ipv4.ip_unprivileged_port_start=${lowest}'" >/dev/null \
        || die "could not lower ip_unprivileged_port_start; set HTTP_PORT/HTTPS_PORT to >=1024 in config.env"
    fi
    ok "podman VM allows binding port ${lowest}"
  fi

  # Container churn exhausts the per-user kernel keyring and new containers then
  # fail with "unable to join session keyring: disk quota exceeded".
  keys=$(podman machine ssh 'cat /proc/sys/kernel/keys/maxkeys' 2>/dev/null || echo 0)
  if [[ "${keys:-0}" -lt 100000 ]]; then
    log "raising kernel keyring limits inside the podman VM"
    podman machine ssh "sudo sh -c 'printf \"kernel.keys.maxkeys=2000000\\nkernel.keys.maxbytes=50000000\\nkernel.keys.root_maxkeys=2000000\\nkernel.keys.root_maxbytes=50000000\\n\" > /etc/sysctl.d/99-kind-keyring.conf && sysctl -p /etc/sysctl.d/99-kind-keyring.conf'" >/dev/null \
      || warn "could not raise kernel.keys.maxkeys; containers may fail with 'disk quota exceeded'"
  fi
  ok "podman VM keyring limit: $(podman machine ssh 'cat /proc/sys/kernel/keys/maxkeys' 2>/dev/null)"

  # Rootless podman delegates only "memory pids cpu io" by default. Without
  # cpuset the kubelet cannot enforce node allocatable and every node logs
  # FailedNodeAllocatableEnforcement ("cpuset.cpus: no such file") forever.
  if ! podman machine ssh 'cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers' 2>/dev/null | grep -qw cpuset; then
    warn "cpuset is not delegated to rootless podman; enabling it"
    warn "this restarts the user systemd slice and will STOP running containers"
    podman machine ssh "sudo sh -c 'mkdir -p /etc/systemd/system/user@.service.d && printf \"[Service]\\nDelegate=memory pids cpu io cpuset\\n\" > /etc/systemd/system/user@.service.d/delegate.conf && systemctl daemon-reload'" >/dev/null 2>&1 \
      || warn "could not write the delegation config"
    warn "restart the podman machine to apply: podman machine stop && podman machine start"
  else
    ok "podman VM delegates cpuset (node allocatable enforcement works)"
  fi
fi

# Our own cluster legitimately holds these ports; only look for foreign ones.
if cluster_exists; then
  ok "cluster '${CLUSTER_NAME}' already exists -- skipping port conflict checks"
  exit 0
fi

for p in "${HTTP_PORT}" "${HTTPS_PORT}" "${API_SERVER_PORT}" "${REGISTRY_HOST_PORT}"; do
  if lsof -nP -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1; then
    if "${CE}" ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${p}->"; then
      warn "port ${p} is held by an existing ${CE} container (probably this stack)"
    else
      die "port ${p} is already in use by another process"
    fi
  fi
done

ok "preflight passed"
