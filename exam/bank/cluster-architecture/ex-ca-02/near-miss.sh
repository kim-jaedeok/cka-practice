#!/usr/bin/env bash
# Near-miss fixture: the scale rule has no resourceNames, so scaler-bot can also
# scale backend.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: frontend-scaler
  namespace: rollouts
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scaler-bot-frontend-scaler
  namespace: rollouts
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: frontend-scaler
subjects:
  - kind: ServiceAccount
    name: scaler-bot
    namespace: rollouts
EOF
kctx -n rollouts scale deploy frontend --replicas=3 \
  --as=system:serviceaccount:rollouts:scaler-bot >/dev/null
wait_deploy rollouts frontend 180s
