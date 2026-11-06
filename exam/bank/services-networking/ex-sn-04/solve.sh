#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: stats-agent
  namespace: node-agents
spec:
  selector:
    app: stats-agent
  internalTrafficPolicy: Local
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9100
      targetPort: 9100
EOF
sleep 3
