#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dept-y patch deploy health-api --type=strategic -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "api",
    "readinessProbe": {
      "httpGet": {"path": "/", "port": 80},
      "initialDelaySeconds": 5,
      "periodSeconds": 10
    },
    "livenessProbe": {
      "tcpSocket": {"port": 80},
      "initialDelaySeconds": 15,
      "periodSeconds": 20
    }
  }]}}}
}'

wait_deploy dept-y health-api 180s
