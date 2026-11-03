#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

cleanup_question ts-16
rm -f -- "$CKA_STATE_DIR/question-data/ts-16/service-fingerprint"
rmdir "$CKA_STATE_DIR/question-data/ts-16" 2>/dev/null || true
