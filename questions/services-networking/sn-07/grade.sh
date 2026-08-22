#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-07

sn07_deployment_fingerprint() {
  kctx -n commerce get deploy payments -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
uid = obj["metadata"]["uid"]
spec = json.dumps(obj["spec"], sort_keys=True, separators=(",", ":"))
print(uid + "|" + hashlib.sha256(spec.encode()).hexdigest())
'
}

sn07_deployment_unchanged() {
  local path="$CKA_STATE_DIR/question-data/sn-07/deployment-fingerprint" expected current
  [ -s "$path" ] \
    || { grade_invalid "sn-07 baseline Deployment fingerprint missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(sn07_deployment_fingerprint)" || return 1
  [ -n "$expected" ] && [ "$current" = "$expected" ]
}

sn07_cross_node_http_ok() {
  local payments_json worker1_target worker2_target
  payments_json="$(kctx -n commerce get pods -l app=payments -o json 2>/dev/null)" \
    || return 1
  python3 -c '
import json, sys
pods = json.loads(sys.argv[1]).get("items", [])
nodes = sorted(pod.get("spec", {}).get("nodeName") for pod in pods)
ready = all(
    any(c.get("type") == "Ready" and c.get("status") == "True"
        for c in pod.get("status", {}).get("conditions", []))
    for pod in pods
)
raise SystemExit(0 if nodes == ["cka-worker", "cka-worker2"] and ready else 1)
' "$payments_json" || return 1
  worker1_target="$(kctx -n commerce get pods -l app=payments \
    --field-selector spec.nodeName=cka-worker2 -o jsonpath='{.items[0].status.podIP}' \
    2>/dev/null)" || return 1
  worker2_target="$(kctx -n commerce get pods -l app=payments \
    --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].status.podIP}' \
    2>/dev/null)" || return 1
  [ -n "$worker1_target" ] && [ -n "$worker2_target" ] || return 1
  pod_ready commerce client-worker1 && pod_ready commerce client-worker2 \
    && kctx -n commerce exec client-worker1 -- wget -q -T 3 -O /dev/null \
      "http://$worker1_target" >/dev/null 2>&1 \
    && kctx -n commerce exec client-worker2 -- wget -q -T 3 -O /dev/null \
      "http://$worker2_target" >/dev/null 2>&1
}

_python3_require || true

criterion 2 "Service targetPort가 컨테이너 포트(80)로 수정됨" \
  "jp_array_count svc payments-svc commerce '{range .spec.ports[*]}{.port}{\"\\n\"}{end}' 1 && \
   jp_relation_has svc payments-svc commerce \
     '{range .spec.ports[*]}{.port}{\"|\"}{.targetPort}{\"|\"}{.protocol}{\"\\n\"}{end}' \
     '80|80|TCP'"

criterion 1 "Deployment는 그대로이고 두 worker 사이 Pod HTTP가 정상" \
  "sn07_deployment_unchanged && deploy_ready commerce payments 2 && \
   sn07_cross_node_http_ok"

criterion 2 "실측: payments-svc HTTP 접근 성공" \
  "svc_has_endpoints commerce payments-svc && \
   http_ok http://payments-svc.commerce.svc.cluster.local"

grade_finish
