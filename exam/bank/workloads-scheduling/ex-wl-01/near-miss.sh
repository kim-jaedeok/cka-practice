#!/usr/bin/env bash
# Near-miss fixture: strategy, history limit and image are right, but no change
# cause is recorded.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n orders patch deploy order-api --type=merge -p '{
  "spec": {
    "revisionHistoryLimit": 5,
    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}
  }
}' >/dev/null
kctx -n orders set image deploy/order-api api=nginx:1.29 >/dev/null
wait_deploy orders order-api 240s
