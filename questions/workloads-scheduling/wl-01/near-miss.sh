#!/usr/bin/env bash
# Adversarial fixture: recreating the Deployment to mimic the final spec must
# not satisfy the explicit "Do not delete" requirement.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dept-x delete deploy api-server --wait=true --timeout=90s >/dev/null
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: dept-x
spec:
  replicas: 4
  selector:
    matchLabels: {app: api-server}
  template:
    metadata:
      labels: {app: api-server}
    spec:
      containers:
        - name: api
          image: nginx:1.28
EOF
wait_deploy dept-x api-server 180s
