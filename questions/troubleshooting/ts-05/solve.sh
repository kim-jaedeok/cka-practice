#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec cka-worker2 systemctl start kubelet
docker exec cka-worker2 systemctl enable kubelet

# 노드가 Ready로 돌아올 때까지 대기
for i in $(seq 1 40); do
  [ "$(kctx get node cka-worker2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 3
done
