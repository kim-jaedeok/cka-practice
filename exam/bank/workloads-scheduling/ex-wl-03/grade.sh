#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-03

# exwl03_rule <podAffinity|podAntiAffinity>
# A required term with topology kubernetes.io/hostname whose selector matches
# web Pods (affinity) or cache Pods (anti-affinity) and not the other kind.
exwl03_rule() {
  local json
  _python3_require || return $?
  json="$(_resource_json deployment cache cache-tier)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
kind = sys.argv[1]
spec = json.load(sys.stdin)["spec"]["template"]["spec"]
terms = ((spec.get("affinity") or {}).get(kind) or {}).get(
    "requiredDuringSchedulingIgnoredDuringExecution", [])
web = {"app": "web", "tier": "frontend"}
cache = {"app": "cache", "tier": "cache"}
def matches(sel, labels):
    if not sel:
        return False
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        key, op, vals = e.get("key"), e.get("operator"), e.get("values") or []
        if op == "In" and labels.get(key) not in vals: return False
        if op == "NotIn" and labels.get(key) in vals: return False
        if op == "Exists" and key not in labels: return False
        if op == "DoesNotExist" and key in labels: return False
    return True
want, other = (web, cache) if kind == "podAffinity" else (cache, web)
ok = any(t.get("topologyKey") == "kubernetes.io/hostname"
         and not t.get("namespaces") and not t.get("namespaceSelector")
         and matches(t.get("labelSelector"), want)
         and not matches(t.get("labelSelector"), other)
         for t in terms)
raise SystemExit(0 if ok else 1)
' "$1"
}

# Live placement: two cache Pods on two different nodes, each next to a web Pod.
exwl03_placement() {
  local json
  json="$(kctx -n cache-tier get pods -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
pods = [p for p in json.load(sys.stdin)["items"]
        if p["status"].get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")]
def nodes(app):
    return [p["spec"].get("nodeName") for p in pods if p["metadata"]["labels"].get("app") == app]
cache, web = nodes("cache"), set(nodes("web"))
ok = len(cache) == 2 and len(set(cache)) == 2 and set(cache) <= web
raise SystemExit(0 if ok else 1)
'
}

_python3_require || true

criterion 2 "cache requires a node running an app=web Pod (podAffinity, hostname)" \
  "exwl03_rule podAffinity"

criterion 2 "cache forbids two cache Pods per node (podAntiAffinity, hostname)" \
  "exwl03_rule podAntiAffinity"

criterion 1 "cache rolled out with 2 Ready replicas" \
  "deploy_ready cache-tier cache 2"

criterion 2 "실측: the cache Pods run on two different nodes that each run a web Pod" \
  "exwl03_placement"

grade_finish
