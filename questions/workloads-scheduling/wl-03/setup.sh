#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-03
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" autoscale

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-cache
  namespace: autoscale
spec:
  replicas: 1
  selector:
    matchLabels: {app: web-cache}
  template:
    metadata:
      labels: {app: web-cache}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
EOF

wait_deploy autoscale web-cache
