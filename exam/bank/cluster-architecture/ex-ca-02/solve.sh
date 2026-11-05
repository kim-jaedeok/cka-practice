#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
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
    resourceNames: ["frontend"]
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
