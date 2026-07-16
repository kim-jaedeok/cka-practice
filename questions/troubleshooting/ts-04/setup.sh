#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-04
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" heavy

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bigmem
  namespace: heavy
spec:
  replicas: 2
  selector:
    matchLabels: {app: bigmem}
  template:
    metadata:
      labels: {app: bigmem}
    spec:
      containers:
        - name: app
          image: nginx:1.29
          resources:
            requests:
              memory: 100Gi
              cpu: 30
EOF
sleep 3
