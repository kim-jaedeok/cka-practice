#!/usr/bin/env bash
# Near-miss fixture: the HPA object is complete, but the Deployment still has
# no CPU request, so the HPA cannot compute utilization (<unknown>).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

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
sleep 30
