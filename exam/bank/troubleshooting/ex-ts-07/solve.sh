#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n media-proc set resources deploy/thumbnailer -c worker --limits=memory=192Mi >/dev/null
kctx -n media-proc rollout status deploy/thumbnailer --timeout=120s >/dev/null
sleep 18
