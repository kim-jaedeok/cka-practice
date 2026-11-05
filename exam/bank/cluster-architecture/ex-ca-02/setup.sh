#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" rollouts

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scaler-bot
  namespace: rollouts
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: rollouts
spec:
  replicas: 1
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: rollouts
spec:
  replicas: 1
  selector:
    matchLabels: {app: backend}
  template:
    metadata:
      labels: {app: backend}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
EOF
wait_deploy rollouts frontend 180s || die "ex-ca-02 frontend가 준비되지 않았습니다."
wait_deploy rollouts backend 180s || die "ex-ca-02 backend가 준비되지 않았습니다."
