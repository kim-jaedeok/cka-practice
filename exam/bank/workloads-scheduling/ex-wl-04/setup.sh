#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-04
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" api-scale

# The container declares no resource requests, so a CPU utilization target
# cannot be computed for its Pods.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quote-api
  namespace: api-scale
spec:
  replicas: 1
  selector:
    matchLabels:
      app: quote-api
  template:
    metadata:
      labels:
        app: quote-api
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: api
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF
wait_deploy api-scale quote-api || die "ex-wl-04 quote-api가 Ready가 아닙니다."
