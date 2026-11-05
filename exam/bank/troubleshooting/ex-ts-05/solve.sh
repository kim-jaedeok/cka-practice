#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n mapping patch deploy geo-resolver --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirst"},
  {"op":"remove","path":"/spec/template/spec/dnsConfig"}
]' >/dev/null
wait_deploy mapping geo-resolver 180s
