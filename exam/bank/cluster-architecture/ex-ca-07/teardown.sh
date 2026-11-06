#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

cleanup_question ex-ca-07
kctx delete runtimeclass sandboxed --ignore-not-found --wait=true >/dev/null
