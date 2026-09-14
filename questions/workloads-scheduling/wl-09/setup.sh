#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-09
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" file-config

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: web-config
  namespace: file-config
type: Opaque
stringData:
  server.conf: |
    events {}
    http {
      server {
        listen 8080;
        location / {
          default_type text/plain;
          return 200 "secret-file-ready\n";
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-web
  namespace: file-config
spec:
  replicas: 1
  selector:
    matchLabels: {app: config-web}
  template:
    metadata:
      labels: {app: config-web}
    spec:
      containers:
        - name: web
          image: nginx:1.29
---
apiVersion: v1
kind: Service
metadata:
  name: config-web
  namespace: file-config
spec:
  selector: {app: config-web}
  ports:
    - port: 8080
      targetPort: 8080
EOF
wait_deploy file-config config-web
