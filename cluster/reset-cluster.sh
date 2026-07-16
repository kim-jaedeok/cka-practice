#!/usr/bin/env bash
# 클러스터 전체 재생성: 완전히 깨끗한 상태에서 다시 시작하고 싶을 때
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

warn "kind 클러스터 '$CKA_CLUSTER_NAME' 를 삭제하고 다시 만듭니다."
kind delete cluster --name "$CKA_CLUSTER_NAME" 2>/dev/null || true
rm -rf "$CKA_STATE_DIR/status" "$CKA_STATE_DIR/exam"
exec bash "$SCRIPT_DIR/setup-cluster.sh"
