#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

ssh cka-control-plane "etcdutl snapshot restore /var/lib/etcd/snapshot-restore-src.db \
  --data-dir /var/lib/etcd/restore-drill"
