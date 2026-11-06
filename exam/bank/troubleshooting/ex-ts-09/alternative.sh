#!/usr/bin/env bash
# Alternative fixture: allow DNS by selecting the CoreDNS Pods (label
# k8s-app=kube-dns) instead of the kube-system namespace. Both forms meet the
# requirements.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cart-egress
  namespace: checkout
spec:
  podSelector:
    matchLabels:
      app: cart
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: catalog
          podSelector:
            matchLabels:
              app: pricing
      ports:
        - protocol: TCP
          port: 8080
EOF
sleep 5
