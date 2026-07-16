#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=st-04
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" project-delta

kctx apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: store-pv
  labels:
    $CKA_LABEL_KEY: $QID
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: store
  hostPath:
    path: /data/store-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: store-data
  namespace: project-delta
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: store
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-store
  namespace: project-delta
spec:
  replicas: 1
  selector:
    matchLabels: {app: web-store}
  template:
    metadata:
      labels: {app: web-store}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
EOF

kctx -n project-delta wait --for=jsonpath='{.status.phase}'=Bound pvc/store-data --timeout=60s >/dev/null
wait_deploy project-delta web-store
