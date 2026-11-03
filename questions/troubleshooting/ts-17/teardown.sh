#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

cleanup_question ts-17
rm -f -- "$CKA_STATE_DIR/question-data/ts-17/legacy-uid"
rmdir "$CKA_STATE_DIR/question-data/ts-17" 2>/dev/null || true
