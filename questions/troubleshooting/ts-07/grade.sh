#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-07

CURRENT="$CKA_WORK_DIR/ts-07/gateway-errors.log"
PREVIOUS="$CKA_WORK_DIR/ts-07/worker-previous.log"

criterion 3 "gateway-errors.log가 gateway의 현재 ERROR 라인 전체와 정확히 일치" \
  "file_exact_filtered_command_output \"$CURRENT\" ERROR \
     kctx -n logging logs api-gateway -c gateway"

criterion 3 "worker-previous.log가 worker의 직전 container 로그와 byte-for-byte 일치" \
  "file_exact_command_output \"$PREVIOUS\" \
     kctx -n logging logs api-gateway -c worker --previous"

grade_finish
