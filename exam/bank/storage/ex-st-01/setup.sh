#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-st-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" vault-archive

# A claim for 1Gi without a selector binds the smallest fit (archive-pv-a).
# Only a selector on both labels reaches archive-pv-c, whose reclaim policy
# starts as Delete. No StorageClass object named "archive" exists, so binding
# is immediate and purely static.
for spec in "a|1Gi|cold|hdd|Retain" "b|2Gi|hot|ssd|Retain" "c|3Gi|cold|ssd|Delete"; do
  IFS='|' read -r suffix size tier media policy <<< "$spec"
  kctx apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: archive-pv-$suffix
  labels:
    $CKA_LABEL_KEY: $QID
    tier: $tier
    media: $media
spec:
  capacity:
    storage: $size
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: $policy
  storageClassName: archive
  hostPath:
    path: /tmp/cka-ex-st-01/$suffix
    type: DirectoryOrCreate
EOF
done

for suffix in a b c; do
  kctx wait --for=jsonpath='{.status.phase}'=Available "pv/archive-pv-$suffix" --timeout=60s >/dev/null \
    || die "ex-st-01 archive-pv-$suffix가 Available이 아닙니다."
done
