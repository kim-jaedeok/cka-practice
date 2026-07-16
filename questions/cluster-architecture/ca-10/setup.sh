#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-10
require_cluster
cleanup_question "$QID"
# 이전 시도의 static pod 매니페스트 제거
docker exec cka-worker rm -f /etc/kubernetes/manifests/static-web.yaml >/dev/null 2>&1 || true
# mirror pod가 사라질 때까지 잠시 대기
for i in $(seq 1 20); do
  kctx get pod static-web-cka-worker -n default >/dev/null 2>&1 || break
  sleep 2
done
