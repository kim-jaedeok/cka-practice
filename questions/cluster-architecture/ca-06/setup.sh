#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-06
require_cluster
# 이전 시도의 drain 상태 복구
kctx uncordon cka-worker2 >/dev/null 2>&1 || true
cleanup_question "$QID"
workdir_reset "$QID"
