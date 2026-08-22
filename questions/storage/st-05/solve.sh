#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — 명령 이력이 아니라 최종 상태/데이터가 채점된다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# PVC를 삭제하기 전에 원본 PV가 지워지지 않게 한다.
kctx patch pv archive-pv --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null

kctx -n storage-lifecycle delete pod archive-writer --wait=true >/dev/null
kctx -n storage-lifecycle delete pvc archive-old --wait=true >/dev/null
kctx wait --for=jsonpath='{.status.phase}'=Released pv/archive-pv \
  --timeout=90s >/dev/null

# Retain PV의 이전 claimRef를 해제해 replacement claim이 다시 바인딩할 수 있게 한다.
kctx patch pv archive-pv --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null

kctx apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archive-restored
  namespace: storage-lifecycle
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: archive-lifecycle
  volumeName: archive-pv
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: archive-reader
  namespace: storage-lifecycle
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: archive
          mountPath: /archive
  volumes:
    - name: archive
      persistentVolumeClaim:
        claimName: archive-restored
EOF

kctx -n storage-lifecycle wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/archive-restored --timeout=90s >/dev/null
wait_pod storage-lifecycle archive-reader 180s
