#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: collector-access
  namespace: telemetry
spec:
  podSelector:
    matchLabels: {app: collector}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {team: edge}
      ports:
        - {protocol: TCP, port: 8080}
    - from:
        - podSelector:
            matchLabels: {role: admin}
      ports:
        - {protocol: TCP, port: 9090}
EOF
sleep 3
