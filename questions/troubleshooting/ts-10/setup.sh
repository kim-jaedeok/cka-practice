#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-10
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" ci-cd

kctx -n ci-cd create serviceaccount deployer >/dev/null
# 잘못된 Role: deployments가 아니라 pods에 대한 권한만 부여
kctx apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer-role
  namespace: ci-cd
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-binding
  namespace: ci-cd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployer-role
subjects:
  - kind: ServiceAccount
    name: deployer
    namespace: ci-cd
EOF
