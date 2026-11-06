#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n tenant-old patch workqueue orders-q --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null
kctx -n tenant-old patch configmap drain-state --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null
kctx wait --for=delete namespace/tenant-old --timeout=120s >/dev/null
