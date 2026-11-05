#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n orders patch deploy order-api --type=merge -p '{
  "spec": {
    "revisionHistoryLimit": 5,
    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}
  }
}' >/dev/null
kctx -n orders set image deploy/order-api api=nginx:1.29 >/dev/null
kctx -n orders annotate deploy/order-api kubernetes.io/change-cause="upgrade nginx to 1.29" \
  --overwrite >/dev/null
wait_deploy orders order-api 240s
