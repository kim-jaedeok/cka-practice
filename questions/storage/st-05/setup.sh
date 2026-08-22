#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=st-05
ST05_STATE_DIR="$CKA_STATE_DIR/question-data/$QID"
ST05_UID_FILE="$ST05_STATE_DIR/baseline-pv-uid"
require_cluster

# 이전 setup의 baseline이 남아 새 PV를 원본으로 오인하지 않게 한다.
# 문제 전용 단일 파일만 지워 다른 시험/진행 상태는 건드리지 않는다.
rm -f -- "$ST05_UID_FILE"
cleanup_question "$QID"
kctx delete pv archive-pv --ignore-not-found --wait=true >/dev/null 2>&1 || true
recreate_ns "$QID" storage-lifecycle

kctx apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: archive-pv
  labels:
    $CKA_LABEL_KEY: $QID
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: archive-lifecycle
  hostPath:
    path: /var/local/cka-st05
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archive-old
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
  name: archive-writer
  namespace: storage-lifecycle
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
  containers:
    - name: writer
      image: busybox:1.36
      command:
        - sh
        - -c
        - printf '%s\n' cka-retained-data > /archive/marker.txt; sync; sleep infinity
      volumeMounts:
        - name: archive
          mountPath: /archive
  volumes:
    - name: archive
      persistentVolumeClaim:
        claimName: archive-old
EOF

wait_pod storage-lifecycle archive-writer 180s
[ "$(kctx -n storage-lifecycle exec archive-writer -- \
    cat /archive/marker.txt 2>/dev/null)" = cka-retained-data ] \
  || die "초기 archive marker 생성 실패"

baseline_pv_uid="$(kctx get pv archive-pv -o jsonpath='{.metadata.uid}' 2>/dev/null)"
[ -n "$baseline_pv_uid" ] || die "archive-pv UID를 저장할 수 없습니다."
umask 077
mkdir -p "$ST05_STATE_DIR"
printf '%s\n' "$baseline_pv_uid" > "$ST05_UID_FILE"
