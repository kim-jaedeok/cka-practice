#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ts-07"
kctx -n logging logs api-gateway -c gateway \
  | grep ERROR > "$CKA_WORK_DIR/ts-07/gateway-errors.log"
kctx -n logging logs api-gateway -c worker --previous \
  > "$CKA_WORK_DIR/ts-07/worker-previous.log"
