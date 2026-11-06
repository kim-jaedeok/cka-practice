#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-07

EXCA07_NODE="${CKA_CLUSTER_NAME}-worker"

exca07_rc_check() { # <mode>
  local json
  json="$(kctx get runtimeclass sandboxed -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
mode, node = sys.argv[1:3]
rc = json.load(sys.stdin)
if mode == "handler":
    ok = rc.get("handler") == "test-handler"
elif mode == "overhead":
    fixed = rc.get("overhead", {}).get("podFixed", {})
    ok = fixed.get("cpu") in ("100m", "0.1") and fixed.get("memory") == "64Mi" and len(fixed) == 2
elif mode == "scheduling":
    sched = rc.get("scheduling", {}) or {}
    ok = sched.get("nodeSelector") == {"kubernetes.io/hostname": node}
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1" "$EXCA07_NODE"
}

exca07_deployment() {
  jp_eq deploy untrusted-runner sandbox-lab '{.spec.template.spec.runtimeClassName}' sandboxed \
    && deploy_ready sandbox-lab untrusted-runner 2
}

# Every running Pod got the RuntimeClass overhead and node selector injected,
# and containerd really started its sandbox with the test-handler runtime.
exca07_pods_real() {
  local json pods pod
  json="$(kctx -n sandbox-lab get pods -l app=untrusted-runner -o json 2>/dev/null)" || return 1
  pods="$(printf '%s' "$json" | python3 -c '
import json, sys
node = sys.argv[1]
items = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
ok = len(items) == 2
for p in items:
    s = p["spec"]
    ok = ok and (s.get("runtimeClassName") == "sandboxed"
                 and s.get("overhead", {}).get("memory") == "64Mi"
                 and s.get("nodeName") == node
                 and p.get("status", {}).get("phase") == "Running")
if not ok:
    raise SystemExit(1)
print(" ".join(p["metadata"]["name"] for p in items))
' "$EXCA07_NODE")" || return 1
  for pod in $pods; do
    node_exec_out "$EXCA07_NODE" \
      "crictl pods --name '^${pod}\$' --namespace sandbox-lab --state ready -o json" \
      | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
raise SystemExit(0 if len(items) == 1 and items[0].get("runtimeHandler") == "test-handler" else 1)
' || return 1
  done
}

_python3_require || true

criterion 2 "RuntimeClass sandboxed uses the extra containerd handler" \
  "exca07_rc_check handler"

criterion 1 "RuntimeClass sandboxed declares a Pod overhead of cpu 100m and memory 64Mi" \
  "exca07_rc_check overhead"

criterion 1 "RuntimeClass sandboxed schedules Pods to cka-worker only" \
  "exca07_rc_check scheduling"

criterion 2 "Deployment untrusted-runner uses sandboxed and has 2 Ready replicas" \
  "exca07_deployment"

criterion 1 "실측: both Pods run on cka-worker with the overhead under test-handler" \
  "exca07_pods_real"

grade_finish
