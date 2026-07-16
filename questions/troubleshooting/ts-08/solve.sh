#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# 메트릭이 잡힐 때까지 대기 (metrics-server 수집 주기)
for i in $(seq 1 30); do
  top="$(kctx -n monitor top pods --no-headers 2>/dev/null | sort -k2 -rh | head -1 | awk '{print $1}')"
  [ "$top" = "metrics-crunch" ] && break
  sleep 5
done

mkdir -p "$CKA_WORK_DIR/ts-08"
kctx -n monitor top pods --no-headers | sort -k2 -rh | head -1 | awk '{print $1}' \
  > "$CKA_WORK_DIR/ts-08/top-pod.txt"
