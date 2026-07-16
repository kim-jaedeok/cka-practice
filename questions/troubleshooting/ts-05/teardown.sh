#!/usr/bin/env bash
# kubelet을 복구한다 (다른 문제에 영향 방지)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
docker exec cka-worker2 systemctl start kubelet >/dev/null 2>&1 || true
docker exec cka-worker2 systemctl enable kubelet >/dev/null 2>&1 || true
