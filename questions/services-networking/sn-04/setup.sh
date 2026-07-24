#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-04
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" web-zone

app_yaml() { # app_yaml <name>
  local name="$1"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}-content
  namespace: web-zone
data:
  index.html: "response from ${name}\n"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: web-zone
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${name}}
  template:
    metadata:
      labels: {app: ${name}}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html/${name#web-}
      volumes:
        - name: content
          configMap:
            name: ${name}-content
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: web-zone
spec:
  selector: {app: ${name}}
  ports:
    - port: 80
      targetPort: 80
EOF
}

app_yaml web-a | kctx apply -f - >/dev/null
app_yaml web-b | kctx apply -f - >/dev/null

wait_deploy web-zone web-a
wait_deploy web-zone web-b
