#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n commerce patch svc payments-svc --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
sleep 3
