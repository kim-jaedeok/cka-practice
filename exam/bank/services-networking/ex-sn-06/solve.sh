#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n shop-frontend delete svc payments --wait=true >/dev/null
kctx -n shop-frontend create service externalname payments \
  --external-name payments-api.payments-core.svc.cluster.local >/dev/null
kctx -n shop-frontend delete deploy payments-legacy --wait=true >/dev/null
kctx -n shop-frontend wait --for=delete pod -l app=payments-legacy --timeout=60s >/dev/null 2>&1 || true
