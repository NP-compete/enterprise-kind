#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cluster_exists || die "cluster '${CLUSTER_NAME}' does not exist"

echo; log "nodes"
kc get nodes -L topology.kubernetes.io/zone,ingress-ready

echo; log "helm releases"
helm list -A --kube-context "${KUBECONTEXT}" -o table | sed 's/\t/  /g'

echo; log "pods that are not Running/Completed"
bad=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' || true)
if [[ -z "${bad}" ]]; then ok "every pod is healthy"; else echo "${bad}"; fi

echo; log "warnings in the last 2 minutes (live problems only)"
# Kubernetes keeps events for an hour, so a UI full of red is usually history.
# This window is what actually matters right now.
kc get events -A --field-selector type=Warning -o json 2>/dev/null | python3 -I -c "
import sys, json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
seen = {}
for e in json.load(sys.stdin)['items']:
    ts = e.get('lastTimestamp') or e.get('eventTime')
    if not ts:
        continue
    age = (now - datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))).total_seconds()
    if age < 120:
        seen[(e['reason'], e['involvedObject'].get('name', ''))] = int(age)
for (reason, name), age in sorted(seen.items(), key=lambda kv: kv[1]):
    print(f'  {age:4}s ago  {reason}  {name}')
if not seen:
    print('  none -- anything red in a UI is older than this and already resolved')
" 2>/dev/null || warn "could not read events"

echo; log "ingresses"
kc get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[*].host,TLS:.spec.tls[*].secretName'

echo; log "certificates"
kc get certificate -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status' 2>/dev/null || true

echo; log "prometheus targets down"
down=$(kc get --raw '/api/v1/namespaces/observability/services/kps-prometheus:9090/proxy/api/v1/targets?state=active' 2>/dev/null \
  | jq -r '.data.activeTargets[] | select(.health!="up") | "  \(.scrapePool)  \(.lastError)"' 2>/dev/null | sort -u)
if [[ -z "${down}" ]]; then ok "every scrape target is up"; else echo "${down}"; fi

echo; log "kyverno policy violations"
kc get policyreport -A --no-headers 2>/dev/null \
  | awk '{f+=$4} END {if (f>0) print "  " f " failing rules -- kubectl get policyreport -A"; else print "  none"}' \
  || warn "kyverno reports unavailable"
echo
