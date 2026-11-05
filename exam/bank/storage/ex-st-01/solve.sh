#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
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
  resources:
    requests:
      storage: 1Gi
  selector:
    matchLabels:
      tier: cold
      media: ssd
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
