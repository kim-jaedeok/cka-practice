#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: asia-svc
  namespace: world
spec:
  type: NodePort
  selector:
    app: asia
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
      protocol: TCP
EOF
sleep 3
