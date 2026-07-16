#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-05
require_cluster
# 이전 시도의 drain 상태 복구
kctx uncordon cka-worker >/dev/null 2>&1 || true
cleanup_question "$QID"
recreate_ns "$QID" upkeep

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maintenance-app
  namespace: upkeep
spec:
  replicas: 4
  selector:
    matchLabels: {app: maintenance-app}
  template:
    metadata:
      labels: {app: maintenance-app}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
EOF

wait_deploy upkeep maintenance-app
