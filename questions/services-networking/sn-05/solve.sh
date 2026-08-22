#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/cell.sh"

cell_activate sn-05 gateway-cell

kctx apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gw
  namespace: traffic
spec:
  gatewayClassName: envoy-cka
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: shop.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store-route
  namespace: traffic
spec:
  parentRefs:
    - name: main-gw
      sectionName: http
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      backendRefs:
        - name: store-svc
          port: 80
EOF

for _ in $(seq 1 120); do
  accepted="$(kctx -n traffic get gateway main-gw -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  programmed="$(kctx -n traffic get gateway main-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  route="$(kctx -n traffic get httproute store-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  [ "$accepted|$programmed|$route" = "True|True|True" ] && exit 0
  sleep 1
done
exit 1
