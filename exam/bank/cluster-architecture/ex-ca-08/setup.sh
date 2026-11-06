#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-08
QDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
require_cluster

# Remove bootstrap tokens left by an earlier run of this question.
bash "$QDIR/teardown.sh" >/dev/null 2>&1 || true
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
date -u +%Y-%m-%dT%H:%M:%SZ > "$CKA_STATE_DIR/question-data/$QID/setup-time"
# Remember the tokens that are still valid now. Expired tokens may be removed
# by the token cleaner at any time, so they are not part of the guard.
kctx -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token -o json \
  | python3 -c '
import base64, datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for s in json.load(sys.stdin)["items"]:
    exp = base64.b64decode(s.get("data", {}).get("expiration", "")).decode()
    if not exp or exp > now:
        print(s["metadata"]["uid"])
' > "$CKA_STATE_DIR/question-data/$QID/existing-token-uids"
