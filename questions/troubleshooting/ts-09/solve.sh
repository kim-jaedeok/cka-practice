#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# storageClassName은 불변이므로 PVC(및 이를 쓰는 Pod)를 재생성한다
kctx -n data-layer delete pod report-app --ignore-not-found --wait=true
kctx -n data-layer delete pvc report-pvc --ignore-not-found --wait=true

kctx apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: report-pvc
  namespace: data-layer
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: reports
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

kctx -n data-layer wait --for=jsonpath='{.status.phase}'=Bound pvc/report-pvc --timeout=60s
wait_pod data-layer report-app
