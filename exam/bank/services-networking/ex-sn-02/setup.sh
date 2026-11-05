#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" docs-portal

# Each backend answers every path with its own fixed body, so the grader can
# tell which Service the controller picked.
for pair in "docs-v1|docs portal v1 (legacy)" "docs-v2|docs portal v2" \
    "status-page|status: all systems operational"; do
  name="${pair%%|*}"
  body="${pair#*|}"
  kctx apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $name-conf
  namespace: docs-portal
data:
  default.conf: |
    server {
      listen 80;
      location / { default_type text/plain; return 200 "$body\n"; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: docs-portal
spec:
  replicas: 1
  selector:
    matchLabels: {app: $name}
  template:
    metadata:
      labels: {app: $name}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: conf
          configMap:
            name: $name-conf
---
apiVersion: v1
kind: Service
metadata:
  name: $name
  namespace: docs-portal
spec:
  selector: {app: $name}
  ports:
    - port: 80
      targetPort: 80
EOF
done

for name in docs-v1 docs-v2 status-page; do
  wait_deploy docs-portal "$name" 180s || die "ex-sn-02 $name이 준비되지 않았습니다."
done
