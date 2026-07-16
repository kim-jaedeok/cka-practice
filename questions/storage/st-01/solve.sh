#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-alpha
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /data/pv-alpha
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-alpha
  namespace: project-alpha
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
EOF

kctx -n project-alpha wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-alpha --timeout=60s
