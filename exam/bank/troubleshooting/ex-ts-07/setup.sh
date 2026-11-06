#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-07
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" media-proc

# The container loads an 80 MB buffer into shell memory at start. That does not
# fit into the 64Mi memory limit, so the kernel kills it (OOMKilled) each time.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thumbnailer
  namespace: media-proc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: thumbnailer
  template:
    metadata:
      labels:
        app: thumbnailer
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: worker
          image: busybox:1.36
          command:
            - sh
            - -c
            - buf="$(head -c 80000000 /dev/zero | tr '\0' x)" && echo "frame buffer ready (${#buf} bytes)" && exec sleep 3600000
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
EOF

# Wait for the first OOM kill so that the fault is visible from the start.
for _ in $(seq 1 45); do
  reason="$(kctx -n media-proc get pods -l app=thumbnailer \
    -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)"
  [ "$reason" = OOMKilled ] && exit 0
  sleep 2
done
die "ex-ts-07 baseline이 OOMKilled 상태가 되지 않았습니다."
