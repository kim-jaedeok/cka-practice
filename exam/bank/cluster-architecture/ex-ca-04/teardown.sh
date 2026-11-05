#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

cleanup_question ex-ca-04
kctx delete csr dana-csr --ignore-not-found --wait=true --timeout=60s >/dev/null
question_state_clear ex-ca-04
