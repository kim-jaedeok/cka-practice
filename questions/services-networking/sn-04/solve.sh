#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: web-zone
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /a
            pathType: Prefix
            backend:
              service:
                name: web-a
                port:
                  number: 80
          - path: /b
            pathType: Prefix
            backend:
              service:
                name: web-b
                port:
                  number: 80
EOF

# ingress-nginx가 룰을 로드할 때까지 잠시 대기
sleep 8
