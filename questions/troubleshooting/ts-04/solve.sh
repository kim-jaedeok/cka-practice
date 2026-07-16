#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n heavy patch deploy bigmem --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "app",
    "resources": {
      "requests": {"memory": "64Mi", "cpu": "50m"},
      "limits":   {"memory": "128Mi", "cpu": "200m"}
    }
  }]}}}
}'
wait_deploy heavy bigmem 180s
