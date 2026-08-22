#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-02
require_cluster
# sn-01과 같은 ns를 공유하지 않도록 asia 전용 리소스만 정리 (world ns는 재사용)
kctx get ns world >/dev/null 2>&1 || { recreate_ns "$QID" world; }
kctx -n world delete deploy asia --ignore-not-found >/dev/null 2>&1 || true
kctx -n world delete svc asia-svc --ignore-not-found >/dev/null 2>&1 || true
workdir_clear "$QID"

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: asia
  namespace: world
spec:
  replicas: 1
  selector:
    matchLabels: {app: asia}
  template:
    metadata:
      labels: {app: asia}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF

wait_deploy world asia
