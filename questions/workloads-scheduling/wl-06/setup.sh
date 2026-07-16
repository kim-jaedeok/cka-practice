#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-06
require_cluster
cleanup_question "$QID"
# 사용자가 직접 만드는 cluster-scoped 리소스는 이름으로 정리
kctx delete priorityclass high-priority --ignore-not-found >/dev/null 2>&1 || true
recreate_ns "$QID" dept-z
