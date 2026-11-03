#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

ip="$(kctx -n fabric get pod trainer-b -o jsonpath='{.status.podIP}')"
mkdir -p "$CKA_WORK_DIR/sn-11"
docker exec cka-worker ip -4 route get "$ip" \
  | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1 > "$CKA_WORK_DIR/sn-11/egress-interface.txt"
