#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-06
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" dns-test
workdir_reset "$QID"

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-dns
  namespace: dns-test
spec:
  replicas: 1
  selector:
    matchLabels: {app: web-dns}
  template:
    metadata:
      labels: {app: web-dns}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: v1
kind: Service
metadata:
  name: web-dns
  namespace: dns-test
spec:
  selector: {app: web-dns}
  ports:
    - port: 80
      targetPort: 80
EOF

wait_deploy dns-test web-dns
