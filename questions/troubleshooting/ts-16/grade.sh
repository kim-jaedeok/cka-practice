#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-16

ts16_service_fingerprint() {
  kctx -n inventory get svc stock-svc -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
spec = {k: obj["spec"].get(k) for k in ("selector", "ports", "type")}
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(
    json.dumps(spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
'
}

ts16_service_unchanged() {
  local path="$CKA_STATE_DIR/question-data/ts-16/service-fingerprint" expected current
  [ -s "$path" ] \
    || { grade_invalid "ts-16 baseline Service fingerprint missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(ts16_service_fingerprint)" || return 1
  [ -n "$expected" ] && [ "$current" = "$expected" ]
}

# The nginx container must keep an HTTP readiness probe that targets port 80,
# either numerically or through a named container port that resolves to 80.
ts16_http_readiness_on_80() {
  local json
  _python3_require || return $?
  json="$(_resource_json deployment stock-api inventory)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
containers = obj.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
ok = False
for c in containers:
    probe = (c.get("readinessProbe") or {}).get("httpGet")
    if not probe:
        continue
    port = probe.get("port")
    if isinstance(port, str):
        port = next((p.get("containerPort") for p in c.get("ports", [])
                     if p.get("name") == port), None)
    ok = ok or port == 80
raise SystemExit(0 if ok else 1)
'
}

_python3_require || true

criterion 2 "Deployment keeps an HTTP readiness probe on port 80" \
  "ts16_http_readiness_on_80"

criterion 1 "Service stock-svc is unchanged" \
  "ts16_service_unchanged"

criterion 1 "stock-api rolled out with 2 Ready Pods" \
  "deploy_ready inventory stock-api 2"

criterion 2 "실측: stock-svc has ready endpoints and serves HTTP" \
  "svc_has_endpoints inventory stock-svc && \
   http_ok http://stock-svc.inventory.svc.cluster.local"

grade_finish
