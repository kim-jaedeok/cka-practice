#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=st-01
require_cluster
cleanup_question "$QID"
# 사용자가 직접 만드는(라벨 없는) 리소스도 이름으로 정리
kctx delete pv pv-alpha --ignore-not-found >/dev/null 2>&1 || true
recreate_ns "$QID" project-alpha
