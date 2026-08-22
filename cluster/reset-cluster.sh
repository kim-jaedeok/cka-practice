#!/usr/bin/env bash
# 클러스터 전체 재생성: 완전히 깨끗한 상태에서 다시 시작하고 싶을 때
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

warn "kind 클러스터 '$CKA_CLUSTER_NAME' 를 삭제하고 다시 만듭니다."
cloud_provider_kind_cleanup_cluster_loadbalancers "$CKA_CLUSTER_NAME" \
  || die "재생성 전 LoadBalancer Service/container 정리에 실패했습니다."
kind delete cluster --name "$CKA_CLUSTER_NAME" \
  || die "kind 클러스터 삭제에 실패했습니다."
state_subdir_clear status \
  || die "문제 상태 디렉터리를 안전하게 정리하지 못했습니다."
state_subdir_clear exam \
  || die "시험 상태 디렉터리를 안전하게 정리하지 못했습니다."
state_subdir_clear backup \
  || die "이전 클러스터의 백업 상태를 안전하게 정리하지 못했습니다."
state_subdir_clear question-data \
  || die "이전 클러스터의 문제 기준 상태를 안전하게 정리하지 못했습니다."
exec bash "$SCRIPT_DIR/setup-cluster.sh"
