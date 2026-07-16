#!/usr/bin/env bash
# drain 상태를 원복한다 (다른 문제에 영향 방지)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
kctx uncordon cka-worker >/dev/null 2>&1 || true
