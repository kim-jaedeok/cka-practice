#!/usr/bin/env bash
# Near-miss fixture: removing the readiness probe makes the Pods Ready, but DNS
# is still broken and the probe had to stay.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n mapping patch deploy geo-resolver --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]' >/dev/null
wait_deploy mapping geo-resolver 180s
