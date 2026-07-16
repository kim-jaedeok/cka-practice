#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" app-track

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: app-track
spec:
  replicas: 3
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      containers:
        - name: nginx
          image: nginx:1.92-fake
EOF
sleep 3
