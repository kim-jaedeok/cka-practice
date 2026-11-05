#!/usr/bin/env bash
# Near-miss fixture: both peers and both ports sit in one ingress rule. Every
# listed peer may then use every listed port.
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
        - podSelector:
            matchLabels: {role: admin}
      ports:
        - {protocol: TCP, port: 8080}
        - {protocol: TCP, port: 9090}
EOF
sleep 3
