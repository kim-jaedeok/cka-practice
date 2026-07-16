#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" mercury

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cleaner
  namespace: mercury
spec:
  replicas: 1
  selector:
    matchLabels: {app: cleaner}
  template:
    metadata:
      labels: {app: cleaner}
    spec:
      containers:
        - name: cleaner-con
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /var/log/cleaner
              i=0
              while true; do
                echo "$(date) cleaner iteration $i" >> /var/log/cleaner/cleaner.log
                i=$((i+1))
                sleep 3
              done
          volumeMounts:
            - name: logs
              mountPath: /var/log/cleaner
      volumes:
        - name: logs
          emptyDir: {}
EOF

wait_deploy mercury cleaner
