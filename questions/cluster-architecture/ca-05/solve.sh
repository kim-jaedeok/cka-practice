#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx drain cka-worker --ignore-daemonsets --delete-emptydir-data --timeout=180s
wait_deploy upkeep maintenance-app 180s
