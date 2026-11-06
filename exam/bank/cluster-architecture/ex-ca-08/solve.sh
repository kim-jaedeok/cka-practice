#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ex-ca-08"
docker exec "$(cka_cp_node)" kubeadm token create --ttl 3h \
  --description "rack-b expansion" --print-join-command \
  > "$CKA_WORK_DIR/ex-ca-08/join-worker.sh"
