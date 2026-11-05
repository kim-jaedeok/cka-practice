#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n render-farm patch deploy renderer --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/volumes/0","value":{
    "name":"scratch",
    "ephemeral":{"volumeClaimTemplate":{"spec":{
      "storageClassName":"standard",
      "accessModes":["ReadWriteOnce"],
      "resources":{"requests":{"storage":"256Mi"}}}}}}}
]' >/dev/null
wait_deploy render-farm renderer 240s
# Claims of deleted Pods are removed by garbage collection shortly after.
for _ in $(seq 1 30); do
  [ "$(kctx -n render-farm get pvc -o name | wc -l)" -eq 2 ] && break
  sleep 2
done
