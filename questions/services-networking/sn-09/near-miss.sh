#!/usr/bin/env bash
# Near miss: the provider assigns an address, but the selector has no endpoints.
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
    app: typo-store
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
EOF

# The semantic miss is the selector, not an unprogrammed provider. Wait until
# the otherwise valid LoadBalancer receives its address so the fixture earns a
# strict partial score rather than racing the controller at 0/8.
for _ in $(seq 1 60); do
  address="$(kctx -n lb-shop get service store-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$address" ] && exit 0
  sleep 1
done
die "near-miss LoadBalancer address was not assigned"
