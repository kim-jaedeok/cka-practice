#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: store-lb
  namespace: lb-shop
spec:
  type: LoadBalancer
  selector:
    app: store
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
EOF

address=""
for _ in $(seq 1 120); do
  address="$(kctx -n lb-shop get service store-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -z "$address" ]; then
    address="$(kctx -n lb-shop get service store-lb \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi
  [ -n "$address" ] && exit 0
  sleep 1
done
die "store-lb did not receive an external address"
