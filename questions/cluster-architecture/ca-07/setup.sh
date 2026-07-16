#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-07
require_cluster
command -v helm >/dev/null || die "helm이 설치되어 있지 않습니다. 'cka cluster up'을 다시 실행하세요."
helm -n helm-apps uninstall webapp-rel >/dev/null 2>&1 || true
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" helm-apps

# 차트를 작업 디렉토리로 복사 (문제에서 참조하는 경로)
cp -r "$(dirname "${BASH_SOURCE[0]}")/chart" "$CKA_WORK_DIR/ca-07/chart"
