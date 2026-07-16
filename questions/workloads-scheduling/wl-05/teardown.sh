#!/usr/bin/env bash
# 이 문제가 노드에 남긴 라벨/taint를 원복한다 (다른 문제에 영향 방지)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
kctx label node cka-worker disktype- >/dev/null 2>&1 || true
kctx taint node cka-worker2 env=prod:NoSchedule- >/dev/null 2>&1 || true
