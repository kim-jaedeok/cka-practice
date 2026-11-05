#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-04
require_cluster
command -v openssl >/dev/null 2>&1 || die "ex-ca-04 setup에는 openssl이 필요합니다."
cleanup_question "$QID"
question_state_clear "$QID"
# CertificateSigningRequests are cluster-scoped and created by the candidate.
kctx delete csr dana-csr --ignore-not-found --wait=true --timeout=60s >/dev/null
workdir_reset "$QID"
recreate_ns "$QID" audit-zone

work="$CKA_WORK_DIR/$QID"
openssl genrsa -out "$work/dana.key" 2048 2>/dev/null
openssl req -new -key "$work/dana.key" -subj "/CN=dana/O=auditors" -out "$work/dana.csr" 2>/dev/null
chmod 0600 "$work/dana.key"

# Keep a trusted copy of the request; only dana.crt is collected at grading.
mkdir -p "$CKA_STATE_DIR/question-data/$QID"
cp "$work/dana.csr" "$CKA_STATE_DIR/question-data/$QID/dana.csr"
