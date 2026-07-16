#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=st-03
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" project-gamma

kctx apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: expandable
  labels:
    $CKA_LABEL_KEY: $QID
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cache-pvc
  namespace: project-gamma
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: expandable
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
  namespace: project-gamma
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: cache
          mountPath: /cache
  volumes:
    - name: cache
      persistentVolumeClaim:
        claimName: cache-pvc
EOF

wait_pod project-gamma cache-pod 180s
