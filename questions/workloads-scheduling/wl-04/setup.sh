#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-04
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" dept-y

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: health-api
  namespace: dept-y
spec:
  replicas: 2
  selector:
    matchLabels: {app: health-api}
  template:
    metadata:
      labels: {app: health-api}
    spec:
      containers:
        - name: api
          image: nginx:1.29
EOF

wait_deploy dept-y health-api
