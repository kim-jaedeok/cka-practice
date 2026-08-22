#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

failed=0
cleanup_question sn-09 || failed=1
kctx -n cka-system delete service sn09-port80-preflight sn09-lb-sentinel \
  --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || failed=1
kctx -n cka-system delete deployment,configmap sn09-lb-sentinel \
  --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || failed=1
question_state_clear sn-09 || failed=1
exit "$failed"
