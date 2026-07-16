#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-03
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
# 이전 스냅샷 제거
docker exec cka-control-plane rm -f /var/lib/etcd/snapshot-cka.db >/dev/null 2>&1 || true
