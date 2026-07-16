#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-05
require_cluster
cleanup_question "$QID"

# kubelet을 정지시켜 NotReady 상황을 만든다
docker exec cka-worker2 systemctl stop kubelet
info "cka-worker2의 kubelet을 정지했습니다. 노드가 NotReady로 바뀌는 데 ~40초 걸립니다."
