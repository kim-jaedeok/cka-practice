#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

cleanup_question sn-12
rm -f -- "$CKA_STATE_DIR/question-data/sn-12/cni-conf-sha256"
rmdir "$CKA_STATE_DIR/question-data/sn-12" 2>/dev/null || true
