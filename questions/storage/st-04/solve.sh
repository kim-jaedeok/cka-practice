#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n project-delta patch deploy web-store --type=strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [
      {"name": "store-data", "persistentVolumeClaim": {"claimName": "store-data"}},
      {"name": "tmp-cache", "emptyDir": {}}
    ],
    "containers": [{
      "name": "nginx",
      "volumeMounts": [
        {"name": "store-data", "mountPath": "/var/www/data"},
        {"name": "tmp-cache", "mountPath": "/tmp/cache"}
      ]
    }]
  }}}
}'

wait_deploy project-delta web-store
