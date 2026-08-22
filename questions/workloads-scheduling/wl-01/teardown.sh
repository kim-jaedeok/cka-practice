#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

rm -f -- "$CKA_STATE_DIR/question-data/wl-01/baseline-deployment-uid"
rmdir "$CKA_STATE_DIR/question-data/wl-01" 2>/dev/null || true
