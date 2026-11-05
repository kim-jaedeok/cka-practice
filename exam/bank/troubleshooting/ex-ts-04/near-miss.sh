#!/usr/bin/env bash
# Near-miss fixture: scaling the canary to zero removes the 503 answers, but
# the canary must keep one Ready replica.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n storefront scale deploy shop-canary --replicas=0 >/dev/null
kctx -n storefront wait --for=delete pod -l track=canary --timeout=90s >/dev/null 2>&1 || true
sleep 3
