#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: edge-local
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
          - cka-worker2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sensor-cache
  namespace: edge-data
spec:
  storageClassName: edge-local
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: sensor-writer
  namespace: edge-data
spec:
  terminationGracePeriodSeconds: 2
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "date > /cache/started && exec sleep 3600000"]
      volumeMounts:
        - name: cache
          mountPath: /cache
  volumes:
    - name: cache
      persistentVolumeClaim:
        claimName: sensor-cache
EOF
kctx -n edge-data wait --for=condition=Ready pod/sensor-writer --timeout=180s >/dev/null
