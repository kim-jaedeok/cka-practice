#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-04

exwl04_hpa() { # <mode>
  local json
  json="$(kctx -n api-scale get hpa.v2.autoscaling quote-api -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
mode = sys.argv[1]
hpa = json.load(sys.stdin)
spec, status = hpa["spec"], hpa.get("status", {})
if mode == "range":
    ref = spec.get("scaleTargetRef", {})
    ok = (ref.get("kind") == "Deployment" and ref.get("name") == "quote-api"
          and ref.get("apiVersion", "apps/v1") == "apps/v1"
          and spec.get("minReplicas") == 2 and spec.get("maxReplicas") == 6)
elif mode == "metric":
    ms = spec.get("metrics", [])
    ok = len(ms) == 1 and ms[0].get("type") == "Resource" and \
        ms[0].get("resource", {}).get("name") == "cpu" and \
        ms[0]["resource"].get("target", {}).get("type") == "Utilization" and \
        ms[0]["resource"]["target"].get("averageUtilization") == 60
elif mode == "behavior":
    down = spec.get("behavior", {}).get("scaleDown", {})
    pols = down.get("policies", [])
    ok = (down.get("stabilizationWindowSeconds") == 120 and len(pols) == 1
          and pols[0].get("type") == "Pods" and pols[0].get("value") == 1
          and pols[0].get("periodSeconds") == 60)
elif mode == "live":
    conds = {c.get("type"): c.get("status") for c in status.get("conditions", [])}
    current = [m for m in status.get("currentMetrics", []) or []
               if m.get("type") == "Resource" and m.get("resource", {}).get("name") == "cpu"]
    ok = (conds.get("ScalingActive") == "True"
          and len(current) == 1
          and current[0]["resource"].get("current", {}).get("averageUtilization") is not None
          and status.get("currentReplicas", 0) >= 2)
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1"
}

exwl04_requests() {
  kctx -n api-scale get deploy quote-api -o json 2>/dev/null | python3 -c '
import json, sys
cs = json.load(sys.stdin)["spec"]["template"]["spec"]["containers"]
ok = len(cs) == 1 and cs[0].get("image") == "nginx:1.29"
res = cs[0].get("resources", {}) if ok else {}
ok = ok and bool(res.get("requests", {}).get("cpu")) and "cpu" not in res.get("limits", {})
raise SystemExit(0 if ok else 1)
'
}

exwl04_live() {
  exwl04_hpa live || return 1
  local ready
  ready="$(kctx -n api-scale get deploy quote-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "${ready:-0}" -ge 2 ]
}

_python3_require || true

criterion 1 "HPA quote-api targets Deployment quote-api with 2 to 6 replicas" \
  "exwl04_hpa range"

criterion 1 "HPA uses one CPU metric with 60% average utilization" \
  "exwl04_hpa metric"

criterion 2 "scale-down: 120s stabilization window, at most 1 Pod per 60s" \
  "exwl04_hpa behavior"

criterion 1 "quote-api requests CPU and sets no CPU limit (image unchanged)" \
  "exwl04_requests"

criterion 2 "실측: HPA reads the CPU utilization and runs at least 2 Ready Pods" \
  "exwl04_live"

grade_finish
