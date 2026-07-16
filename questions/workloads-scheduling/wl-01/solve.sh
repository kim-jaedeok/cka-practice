#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dept-x rollout undo deploy/api-server
kctx -n dept-x scale deploy/api-server --replicas=4
wait_deploy dept-x api-server 180s
