#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-07
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" commerce

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: commerce
spec:
  replicas: 2
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: payments-svc
  namespace: commerce
spec:
  selector: {app: payments}
  ports:
    - port: 80
      targetPort: 8080
EOF

wait_deploy commerce payments
