#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-08
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" kust-prod

# kustomize 프로젝트를 작업 디렉토리로 복사
cp -r "$(dirname "${BASH_SOURCE[0]}")/files/." "$CKA_WORK_DIR/ca-08/"
