#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-03

wl03_cpu_metric_is_exact() {
  kctx -n autoscale get hpa web-cache-hpa -o json 2>/dev/null | python3 -c '
import json, sys
metrics = json.load(sys.stdin).get("spec", {}).get("metrics", [])
ok = len(metrics) == 1
if ok:
    metric = metrics[0]
    resource = metric.get("resource", {})
    target = resource.get("target", {})
    ok = (
        metric.get("type") == "Resource"
        and resource.get("name") == "cpu"
        and target.get("type") == "Utilization"
        and target.get("averageUtilization") == 60
    )
raise SystemExit(0 if ok else 1)
'
}

wl03_hpa_is_active() {
  local result
  for _ in $(seq 1 15); do
    result="$(kctx -n autoscale get hpa web-cache-hpa \
      -o jsonpath='{.status.currentReplicas}|{.status.desiredReplicas}|{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' \
      2>/dev/null || true)"
    case "$result" in
      2\|2\|*AbleToScale=True*ScalingActive=True*|2\|2\|*ScalingActive=True*AbleToScale=True*)
        return 0
        ;;
    esac
    sleep 2
  done
  return 1
}

_python3_require || true

criterion 2 "HPA web-cache-hpa가 Deployment web-cache를 대상으로 존재" \
  "jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.scaleTargetRef.apiVersion}' apps/v1 && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.scaleTargetRef.kind}' Deployment && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.scaleTargetRef.name}' web-cache"

criterion 2 "min 2 / max 5 replicas 설정" \
  "jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.minReplicas}' 2 && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.maxReplicas}' 5"

criterion 1 "CPU 평균 사용률 60% 목표 메트릭" \
  "wl03_cpu_metric_is_exact"

criterion 1 "HPA controller가 active이고 Deployment를 최소 2개로 스케일" \
  "wl03_hpa_is_active && deploy_ready autoscale web-cache 2"

grade_finish
