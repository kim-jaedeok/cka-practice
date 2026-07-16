#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-07
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" logging
workdir_reset "$QID"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: api-gateway
  namespace: logging
spec:
  containers:
    - name: gateway
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          i=1
          while [ $i -le 30 ]; do
            if [ $((i % 5)) -eq 0 ]; then
              echo "2026-07-16 10:0$((i % 10)):00 ERROR upstream timeout code=E$i"
            else
              echo "2026-07-16 10:0$((i % 10)):00 INFO request handled id=$i"
            fi
            i=$((i+1))
          done
          sleep infinity
EOF

wait_pod logging api-gateway
sleep 3   # 로그가 다 쌓일 때까지
