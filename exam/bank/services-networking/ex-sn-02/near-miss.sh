#!/usr/bin/env bash
# Near-miss fixture: /status uses pathType Prefix, so /status/history is also
# sent to status-page.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: docs-portal
spec:
  ingressClassName: nginx
  rules:
    - host: docs.portal.test
      http:
        paths:
          - path: /status
            pathType: Prefix
            backend:
              service: {name: status-page, port: {number: 80}}
          - path: /
            pathType: Prefix
            backend:
              service: {name: docs-v2, port: {number: 80}}
    - host: legacy.portal.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: docs-v1, port: {number: 80}}
EOF
for _ in $(seq 1 30); do
  if kctx -n cka-system exec deploy/grader-client -- wget -q -O - -T 3 \
      --header "Host: legacy.portal.test" \
      http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/ 2>/dev/null \
      | grep -Fq 'docs portal v1'; then
    break
  fi
  sleep 2
done
