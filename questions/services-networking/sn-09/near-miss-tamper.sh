#!/usr/bin/env bash
# Near miss: the Service is correct, but the candidate also blocks the workload.
# This must be a candidate FAIL, never an infrastructure INVALID result.
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-store-ingress
  namespace: lb-shop
spec:
  podSelector:
    matchLabels:
      app: store
  policyTypes:
    - Ingress
  ingress: []
EOF

for _ in $(seq 1 60); do
  address="$(kctx -n lb-shop get service store-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$address" ] && exit 0
  sleep 1
done
die "tamper near-miss LoadBalancer address was not assigned"
