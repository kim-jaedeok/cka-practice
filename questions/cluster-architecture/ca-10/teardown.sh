#!/usr/bin/env bash
# static pod 매니페스트를 제거한다
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
docker exec cka-worker rm -f /etc/kubernetes/manifests/static-web.yaml >/dev/null 2>&1 || true
