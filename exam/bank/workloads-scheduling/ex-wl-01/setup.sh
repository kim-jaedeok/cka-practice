#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" orders

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-api
  namespace: orders
spec:
  replicas: 4
  selector:
    matchLabels: {app: order-api}
  template:
    metadata:
      labels: {app: order-api}
    spec:
      containers:
        - name: api
          image: nginx:1.28
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: {path: /, port: 80}
            periodSeconds: 2
EOF
wait_deploy orders order-api 180s || die "ex-wl-01 order-api가 준비되지 않았습니다."
