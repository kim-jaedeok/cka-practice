#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-05

ST05_STATE_DIR="$CKA_STATE_DIR/question-data/st-05"
ST05_UID_FILE="$ST05_STATE_DIR/baseline-pv-uid"

st05_original_pv_unchanged() {
  local baseline_uid current_uid
  if [ ! -r "$ST05_UID_FILE" ]; then
    grade_invalid "st-05 baseline PV UID unavailable" || true
    return 2
  fi
  IFS= read -r baseline_uid < "$ST05_UID_FILE" || true
  if [ -z "$baseline_uid" ]; then
    grade_invalid "st-05 baseline PV UID is empty" || true
    return 2
  fi
  current_uid="$(kctx get pv archive-pv -o jsonpath='{.metadata.uid}' 2>/dev/null)" \
    || return 1
  [ "$current_uid" = "$baseline_uid" ]
}

# archive 용 volume 이름은 자유롭지만, 그 volume이 archive-restored를 참조하고
# 동일한 이름의 mount가 /archive에 있어야 한다. 이렇게 검사해 서로 다른
# 배열 원소의 claimName과 mountPath를 섞어 통과시키는 오탐을 막는다.
st05_reader_contract() {
  local manifest
  command -v python3 >/dev/null 2>&1 || {
    grade_invalid "grading dependency unavailable: python3" || true
    return 2
  }
  manifest="$(kctx -n storage-lifecycle get pod archive-reader -o json 2>/dev/null)" \
    || return 1
  python3 -c '
import json
import sys

pod = json.load(sys.stdin)
spec = pod.get("spec", {})
containers = spec.get("containers", [])
if len(containers) != 1 or containers[0].get("image") != "busybox:1.36":
    raise SystemExit(1)

claim_volumes = [
    v for v in spec.get("volumes", [])
    if v.get("persistentVolumeClaim", {}).get("claimName") == "archive-restored"
]
if len(claim_volumes) != 1:
    raise SystemExit(1)
volume_name = claim_volumes[0].get("name")

archive_mounts = [
    m for m in containers[0].get("volumeMounts", [])
    if m.get("mountPath") == "/archive"
]
ok = (
    bool(volume_name)
    and len(archive_mounts) == 1
    and archive_mounts[0].get("name") == volume_name
)
raise SystemExit(0 if ok else 1)
' <<< "$manifest"
}

criterion 2 "archive-pv가 원본 UID로 Retain 및 단일 ReadWriteOnce를 보존" \
  "st05_original_pv_unchanged && \
   jp_eq pv archive-pv - '{.spec.persistentVolumeReclaimPolicy}' Retain && \
   jp_array_has pv archive-pv - '{.spec.accessModes[*]}' ReadWriteOnce && \
   jp_array_count pv archive-pv - '{.spec.accessModes[*]}' 1"

criterion 1 "기존 archive-writer와 archive-old가 제거됨" \
  "res_exists namespace storage-lifecycle && \
   ! res_exists pod archive-writer storage-lifecycle && \
   ! res_exists pvc archive-old storage-lifecycle"

criterion 2 "archive-restored가 원래 PV에 RWO로 Bound" \
  "jp_eq pvc archive-restored storage-lifecycle '{.status.phase}' Bound && \
   jp_eq pvc archive-restored storage-lifecycle '{.spec.volumeName}' archive-pv && \
   jp_eq pvc archive-restored storage-lifecycle '{.spec.storageClassName}' archive-lifecycle && \
   jp_eq pvc archive-restored storage-lifecycle '{.spec.resources.requests.storage}' 1Gi && \
   jp_array_has pvc archive-restored storage-lifecycle '{.spec.accessModes[*]}' ReadWriteOnce && \
   jp_array_count pvc archive-restored storage-lifecycle '{.spec.accessModes[*]}' 1"

criterion 1 "archive-reader가 busybox로 원래 PV를 cka-worker에서 사용하며 Ready" \
  "pod_ready storage-lifecycle archive-reader && \
   jp_eq pod archive-reader storage-lifecycle '{.spec.nodeName}' cka-worker && \
   st05_reader_contract"

criterion 2 "원래 volume의 marker 데이터가 보존됨" \
  "[ \"\$(kctx -n storage-lifecycle exec archive-reader -- \
       cat /archive/marker.txt 2>/dev/null)\" = cka-retained-data ]"

grade_finish
