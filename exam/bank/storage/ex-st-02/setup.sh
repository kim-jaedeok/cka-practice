#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-st-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" render-farm

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: renderer
  namespace: render-farm
spec:
  replicas: 2
  selector:
    matchLabels: {app: renderer}
  template:
    metadata:
      labels: {app: renderer}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "date > /scratch/started && sleep infinity"]
          volumeMounts:
            - name: scratch
              mountPath: /scratch
      volumes:
        - name: scratch
          emptyDir: {}
EOF
wait_deploy render-farm renderer 180s || die "ex-st-02 renderer가 준비되지 않았습니다."
