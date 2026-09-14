#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n file-config patch deployment config-web --type=strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [{"name": "app-config", "secret": {"secretName": "web-config"}}],
    "containers": [{
      "name": "web",
      "command": ["nginx"],
      "args": ["-c", "/etc/app/server.conf", "-g", "daemon off;"],
      "volumeMounts": [{"name": "app-config", "mountPath": "/etc/app", "readOnly": true}]
    }]
  }}}
}'
wait_deploy file-config config-web 180s
