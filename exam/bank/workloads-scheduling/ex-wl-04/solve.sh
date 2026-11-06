#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n api-scale set resources deploy/quote-api -c api --requests=cpu=50m >/dev/null
kctx apply -f - >/dev/null <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: quote-api
  namespace: api-scale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: quote-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
EOF
kctx -n api-scale rollout status deploy/quote-api --timeout=120s >/dev/null

# Wait until metrics-server reports the new Pods and the HPA computes a value.
for _ in $(seq 1 60); do
  util="$(kctx -n api-scale get hpa quote-api \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
  ready="$(kctx -n api-scale get deploy quote-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [ -n "$util" ] && [ "${ready:-0}" -ge 2 ] && exit 0
  sleep 5
done
exit 1
