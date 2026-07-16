#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" batch-jobs

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: batch-jobs
spec:
  replicas: 2
  selector:
    matchLabels: {app: worker}
  template:
    metadata:
      labels: {app: worker}
    spec:
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "echo 'worker booting...'; exit 1"]
EOF
sleep 3
