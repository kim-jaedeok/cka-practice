#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n mercury patch deploy cleaner --type=strategic -p '{
  "spec": {"template": {"spec": {
    "initContainers": [{
      "name": "logger-con",
      "image": "busybox:1.36",
      "restartPolicy": "Always",
      "command": ["sh", "-c", "tail -n+1 -F /var/log/cleaner/cleaner.log"],
      "volumeMounts": [{"name": "logs", "mountPath": "/var/log/cleaner"}]
    }]
  }}}
}'

wait_deploy mercury cleaner 180s
sleep 5   # 로그가 몇 줄 쌓일 때까지 잠깐 대기
