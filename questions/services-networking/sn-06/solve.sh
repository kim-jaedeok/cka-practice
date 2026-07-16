#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dns-test run dns-checker --image=busybox:1.36 --restart=Never \
  --command -- sleep infinity 2>/dev/null || true
wait_pod dns-test dns-checker

mkdir -p "$CKA_WORK_DIR/sn-06"
kctx -n dns-test exec dns-checker -- nslookup web-dns.dns-test.svc.cluster.local \
  > "$CKA_WORK_DIR/sn-06/svc.txt"
kctx -n dns-test exec dns-checker -- nslookup kubernetes.default.svc.cluster.local \
  > "$CKA_WORK_DIR/sn-06/kubernetes.txt"
