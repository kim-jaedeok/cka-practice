#!/usr/bin/env bash
# Near-miss fixture: the Service and its ports are right, but traffic is spread
# over the agents on all nodes (default internalTrafficPolicy Cluster).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: stats-agent
  namespace: node-agents
spec:
  selector:
    app: stats-agent
  ports:
    - name: http
      port: 80
      targetPort: web
    - name: metrics
      port: 9100
      targetPort: metrics
EOF
sleep 3
