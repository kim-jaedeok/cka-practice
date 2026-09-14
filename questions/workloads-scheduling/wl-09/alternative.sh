#!/usr/bin/env bash
# 다른 볼륨 이름과 command/args 분할도 정답으로 인정해야 한다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
kctx -n file-config patch deploy config-web --type=strategic -p '{
  "spec":{"template":{"spec":{
    "volumes":[{"name":"settings","secret":{"secretName":"web-config","items":[{"key":"server.conf","path":"server.conf"}]}}],
    "containers":[{
      "name":"web",
      "command":["nginx","-c","/etc/app/server.conf","-g","daemon off;"],
      "args":[],
      "volumeMounts":[{"name":"settings","mountPath":"/etc/app","readOnly":true}]
    }]
  }}}
}'
wait_deploy file-config config-web 180s
