#!/usr/bin/env bash
# The object specs look plausible, but allowedRoutes rejects this namespace.
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
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              route-access: allowed
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
  hostnames: [shop.example.com]
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      backendRefs:
        - name: store-svc
          port: 80
EOF
