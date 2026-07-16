#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-05
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" traffic

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store
  namespace: traffic
spec:
  replicas: 1
  selector:
    matchLabels: {app: store}
  template:
    metadata:
      labels: {app: store}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: v1
kind: Service
metadata:
  name: store-svc
  namespace: traffic
spec:
  selector: {app: store}
  ports:
    - port: 80
      targetPort: 80
EOF

wait_deploy traffic store
