#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

cleanup_question sn-07
rm -f -- "$CKA_STATE_DIR/question-data/sn-07/deployment-fingerprint"
rmdir "$CKA_STATE_DIR/question-data/sn-07" 2>/dev/null || true
