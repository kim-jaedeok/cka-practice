#!/usr/bin/env bash
# Near-miss fixture: the StorageClass has no topology restriction. The Pod is
# pinned with a nodeSelector instead, which the task forbids.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: edge-local
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
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
  nodeSelector:
    kubernetes.io/hostname: cka-worker2
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
