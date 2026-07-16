#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" world

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: europe
  namespace: world
spec:
  replicas: 2
  selector:
    matchLabels: {app: europe}
  template:
    metadata:
      labels: {app: europe}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF

wait_deploy world europe
