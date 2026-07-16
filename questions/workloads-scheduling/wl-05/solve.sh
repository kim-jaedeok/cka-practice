#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ssd-app
  namespace: scheduling
spec:
  replicas: 2
  selector:
    matchLabels: {app: ssd-app}
  template:
    metadata:
      labels: {app: ssd-app}
    spec:
      nodeSelector:
        disktype: ssd
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: v1
kind: Pod
metadata:
  name: prod-pod
  namespace: scheduling
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker2
  tolerations:
    - key: env
      operator: Equal
      value: prod
      effect: NoSchedule
  containers:
    - name: nginx
      image: nginx:1.29
EOF

wait_deploy scheduling ssd-app
wait_pod scheduling prod-pod
