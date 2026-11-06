#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-04

exsn04_service_shape() {
  kctx -n node-agents get svc stats-agent -o json 2>/dev/null | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]
ports = {p.get("name"): p for p in spec.get("ports", [])}
def port_ok(name, port, targets):
    p = ports.get(name, {})
    return (p.get("port") == port and p.get("targetPort") in targets
            and p.get("protocol", "TCP") == "TCP")
ok = (spec.get("type", "ClusterIP") == "ClusterIP"
      and spec.get("clusterIP") not in (None, "", "None")
      and spec.get("selector") == {"app": "stats-agent"}
      and len(ports) == 2
      and port_ok("http", 80, (8080, "web"))
      and port_ok("metrics", 9100, (9100, "metrics")))
raise SystemExit(0 if ok else 1)
'
}

# From every reporter Pod, all answers must come from the agent on the same
# node as that Pod.
exsn04_local_answers() { # <port-suffix> <expected-prefix> <requests>
  local pods line pod node out
  deploy_ready node-agents reporter 2 || return 1
  svc_has_endpoints node-agents stats-agent || return 1
  pods="$(kctx -n node-agents get pods -l app=reporter \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$pods" | grep -c .)" -eq 2 ] || return 1
  while read -r pod node; do
    [ -n "$pod" ] || continue
    out="$(timeout 40 kubectl --context "$CKA_CONTEXT" -n node-agents exec "$pod" -- sh -c "
      i=0
      while [ \$i -lt $3 ]; do
        wget -q -O - -T 3 http://stats-agent.node-agents.svc.cluster.local$1/ || echo FAILED
        i=\$((i + 1))
      done" 2>/dev/null)" || return 1
    [ "$(printf '%s\n' "$out" | grep -c .)" -eq "$3" ] || return 1
    printf '%s\n' "$out" | grep -Fxv "$2$node" | grep -q . && return 1
  done <<< "$pods"
  return 0
}

_python3_require || true

criterion 2 "Service stats-agent selects the agents with ports http 80->8080 and metrics 9100->9100" \
  "exsn04_service_shape"

criterion 1 "Service stats-agent keeps in-cluster traffic on the client's node" \
  "jp_eq svc stats-agent node-agents '{.spec.internalTrafficPolicy}' Local"

criterion 2 "실측: each reporter Pod always reaches the agent on its own node (port 80)" \
  "exsn04_local_answers '' 'agent on ' 6"

criterion 1 "실측: each reporter Pod reaches the metrics of its own node (port 9100)" \
  "exsn04_local_answers ':9100' 'metrics node=' 2"

grade_finish
