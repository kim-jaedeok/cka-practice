#!/usr/bin/env bash
# Adversarial fixture: deleting/recreating the protected Deployment and fixing
# the Service reaches a superficially healthy state but violates the task.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n commerce delete deploy payments --wait=true --timeout=90s >/dev/null
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: commerce
spec:
  replicas: 2
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: payments}
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF
kctx -n commerce patch service payments-svc --type=merge \
  -p '{"spec":{"ports":[{"port":80,"targetPort":80,"protocol":"TCP"}]}}' >/dev/null
wait_deploy commerce payments 180s
