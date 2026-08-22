#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-web
  namespace: affinity-spread
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-web
  template:
    metadata:
      labels:
        app: spread-web
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: cka-practice/wl07
                    operator: In
                    values:
                      - eligible
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: spread-web
      containers:
        - name: nginx
          image: nginx:1.29
EOF

wait_deploy affinity-spread spread-web 180s
