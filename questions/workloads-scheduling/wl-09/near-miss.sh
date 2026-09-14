#!/usr/bin/env bash
# Secret 파일은 있지만 nginx가 기본 설정을 사용하는 오답.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
bash "$(dirname "${BASH_SOURCE[0]}")/solve.sh"
kctx -n file-config patch deploy config-web --type=strategic -p '{
  "spec":{"template":{"spec":{"containers":[{
    "name":"web","command":["nginx"],"args":["-g","daemon off;"]
  }]}}}
}'
wait_deploy file-config config-web 180s
