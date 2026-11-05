#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-01

exsn01_legacy_unchanged() {
  local path="$CKA_STATE_DIR/question-data/ex-sn-01/legacy-uid" expected
  [ -s "$path" ] \
    || { grade_invalid "ex-sn-01 baseline Pod UID missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  jp_eq pod legacy-app legacy-host '{.metadata.uid}' "$expected" && \
  pod_ready legacy-host legacy-app
}

exsn01_service() {
  local json
  _python3_require || return $?
  json="$(_resource_json service legacy-api bridge)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
spec = json.load(sys.stdin).get("spec", {})
ports = spec.get("ports", [])
ok = (not spec.get("selector") and spec.get("type", "ClusterIP") == "ClusterIP"
      and spec.get("clusterIP") not in (None, "", "None")
      and len(ports) == 1 and ports[0].get("name") == "http"
      and ports[0].get("port") == 8080 and ports[0].get("protocol", "TCP") == "TCP")
raise SystemExit(0 if ok else 1)
'
}

exsn01_slice() {
  local json ip
  _python3_require || return $?
  ip="$(_jp_get pod legacy-app legacy-host '{.status.podIP}')" || return 1
  [ -n "$ip" ] || return 1
  json="$(_resource_json endpointslice legacy-api-1 bridge)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
s = json.load(sys.stdin)
ip = sys.argv[1]
labels = s.get("metadata", {}).get("labels", {})
ports = s.get("ports") or []
addresses = [a for e in s.get("endpoints", []) for a in e.get("addresses", [])
             if (e.get("conditions") or {}).get("ready", True) is not False]
ok = (labels.get("kubernetes.io/service-name") == "legacy-api"
      and s.get("addressType") == "IPv4"
      and addresses == [ip]
      and any(p.get("name") == "http" and p.get("port") == 80
              and p.get("protocol", "TCP") == "TCP" for p in ports))
raise SystemExit(0 if ok else 1)
' "$ip"
}

_python3_require || true

criterion 1 "Service legacy-api is a selectorless ClusterIP with port http/8080" \
  "exsn01_service"

criterion 2 "EndpointSlice legacy-api-1 points legacy-api at the legacy-app IP on port http/80" \
  "exsn01_slice"

criterion 1 "legacy-app is the original Pod and is Ready" \
  "exsn01_legacy_unchanged"

criterion 2 "실측: legacy-api.bridge:8080 is answered by legacy-app" \
  "http_body_contains http://legacy-api.bridge.svc.cluster.local:8080/ 'legacy inventory system v1'"

grade_finish
