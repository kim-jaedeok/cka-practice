#!/usr/bin/env bash
# Near-miss fixture: the claim names the volume with volumeName instead of a
# label selector. It binds, but requirement 1 asked for a selector.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx patch pv archive-pv-c -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vault-claim
  namespace: vault-archive
spec:
  storageClassName: archive
  accessModes: ["ReadWriteOnce"]
  volumeName: archive-pv-c
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: vault-writer
  namespace: vault-archive
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo sealed > /vault/state.txt && sleep infinity"]
      volumeMounts:
        - name: vault
          mountPath: /vault
  volumes:
    - name: vault
      persistentVolumeClaim:
        claimName: vault-claim
EOF
wait_pod vault-archive vault-writer 180s
