#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-08
require_cluster
workdir_reset "$QID"

# CoreDNS 원본 Corefile을 최초 1회 백업 (teardown에서 복원)
mkdir -p "$CKA_STATE_DIR/backup"
if [ ! -f "$CKA_STATE_DIR/backup/coredns-corefile.txt" ]; then
  kctx -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' \
    > "$CKA_STATE_DIR/backup/coredns-corefile.txt"
fi

# 이미 log 플러그인이 있으면 제거된 원본으로 복원 (재도전 대비)
bash "$(dirname "${BASH_SOURCE[0]}")/teardown.sh"
