#!/usr/bin/env bash
# Near-miss fixture: internalTrafficPolicy only affects traffic from inside the
# cluster, so external clients are still source-NATed to a node IP.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n edge patch svc echo-svc -p '{"spec":{"internalTrafficPolicy":"Local"}}' >/dev/null
sleep 3
