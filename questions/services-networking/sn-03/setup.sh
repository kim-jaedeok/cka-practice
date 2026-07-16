#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-03
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" secure-apps

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: db
  namespace: secure-apps
  labels: {role: db}
spec:
  containers:
    - name: nginx
      image: nginx:1.29
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: db-svc
  namespace: secure-apps
spec:
  selector: {role: db}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: secure-apps
  labels: {role: backend}
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: other
  namespace: secure-apps
  labels: {role: other}
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
EOF

wait_pod secure-apps db
wait_pod secure-apps backend
wait_pod secure-apps other
