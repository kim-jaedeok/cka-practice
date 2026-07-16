#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" dept-x

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: dept-x
spec:
  replicas: 2
  selector:
    matchLabels: {app: api-server}
  template:
    metadata:
      labels: {app: api-server}
    spec:
      containers:
        - name: api
          image: nginx:1.28
EOF
wait_deploy dept-x api-server

# 고장난 이미지로 업데이트 → 롤아웃이 막힌 상태를 만든다
kctx -n dept-x set image deploy/api-server api=nginx:1.99-broken >/dev/null
sleep 3
