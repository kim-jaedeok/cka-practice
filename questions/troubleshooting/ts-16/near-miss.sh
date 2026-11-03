#!/usr/bin/env bash
# Near-miss fixture: removing the readiness probe makes traffic flow, but it
# violates the requirement to keep an HTTP readiness probe on port 80.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n inventory patch deploy stock-api --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]' >/dev/null
wait_deploy inventory stock-api 180s
sleep 3
