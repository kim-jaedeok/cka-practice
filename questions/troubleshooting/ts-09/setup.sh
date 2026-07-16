#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-09
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" data-layer

kctx apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: report-pv
  labels:
    $CKA_LABEL_KEY: $QID
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: reports
  hostPath:
    path: /data/report-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: report-pvc
  namespace: data-layer
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: report
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: report-app
  namespace: data-layer
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: reports
          mountPath: /reports
  volumes:
    - name: reports
      persistentVolumeClaim:
        claimName: report-pvc
EOF
sleep 2
