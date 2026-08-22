#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
ST05_STATE_DIR="$CKA_STATE_DIR/question-data/st-05"
ST05_UID_FILE="$ST05_STATE_DIR/baseline-pv-uid"

kctx delete namespace storage-lifecycle --ignore-not-found --wait=true \
  >/dev/null 2>&1 || true
kctx delete pv archive-pv --ignore-not-found --wait=true >/dev/null 2>&1 || true
rm -f -- "$ST05_UID_FILE"
rmdir -- "$ST05_STATE_DIR" >/dev/null 2>&1 || true
