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
  restartPolicy: Always
  containers:
    - name: gateway
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "2026-08-22T10:00:00Z INFO gateway started"
          echo "2026-08-22T10:00:01Z ERROR upstream timeout code=E10"
          echo "2026-08-22T10:00:02Z WARN retrying request"
          echo "2026-08-22T10:00:03Z ERROR backend unavailable code=E20"
          echo "2026-08-22T10:00:04Z INFO request recovered"
          echo "2026-08-22T10:00:05Z ERROR circuit open code=E30"
          sleep infinity
    - name: worker
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          if [ ! -f /state/restarted ]; then
            echo "2026-08-22T10:01:00Z INFO worker booting"
            echo "2026-08-22T10:01:01Z ERROR worker crashed code=W1"
            touch /state/restarted
            exit 1
          fi
          echo "2026-08-22T10:01:10Z INFO worker recovered"
          sleep infinity
      volumeMounts:
        - name: worker-state
          mountPath: /state
    - name: metrics
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "2026-08-22T10:02:00Z ERROR this line belongs to metrics"
          sleep infinity
  volumes:
    - name: worker-state
      emptyDir: {}
EOF

for _ in $(seq 1 60); do
  restart_count="$(kctx -n logging get pod api-gateway \
    -o jsonpath='{.status.containerStatuses[?(@.name=="worker")].restartCount}' \
    2>/dev/null || true)"
  [ "${restart_count:-0}" -ge 1 ] 2>/dev/null && break
  sleep 1
done
[ "${restart_count:-0}" -ge 1 ] 2>/dev/null \
  || die "worker container가 예상대로 재시작하지 않았습니다."
wait_pod logging api-gateway
