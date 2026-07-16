#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dept-z create configmap app-config \
  --from-literal=DB_HOST=db.example.com \
  --from-literal=LOG_LEVEL=warn

kctx -n dept-z create secret generic app-secret \
  --from-literal=DB_PASS='S3cretPass!'

kctx apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 100000
globalDefault: false
description: "High priority workloads"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-app
  namespace: dept-z
spec:
  replicas: 1
  selector:
    matchLabels: {app: config-app}
  template:
    metadata:
      labels: {app: config-app}
    spec:
      priorityClassName: high-priority
      containers:
        - name: app
          image: busybox:1.36
          command: ["sleep", "infinity"]
          envFrom:
            - configMapRef:
                name: app-config
          env:
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASS
EOF

wait_deploy dept-z config-app 180s
