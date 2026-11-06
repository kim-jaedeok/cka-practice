#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-08
DATA="$CKA_STATE_DIR/question-data/$QID"

# Delete the tokens this question asked for, and any other bootstrap token
# that was created after the setup of this question.
since=""
[ -s "$DATA/setup-time" ] && since="$(tr -d '\r\n' < "$DATA/setup-time")"
kctx -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token -o json \
  | python3 -c '
import base64, json, sys
since = sys.argv[1]
for s in json.load(sys.stdin)["items"]:
    data = s.get("data", {})
    desc = base64.b64decode(data.get("description", "")).decode(errors="replace")
    created = s["metadata"]["creationTimestamp"]
    if desc == "rack-b expansion" or (since and created >= since):
        print(s["metadata"]["name"])
' "$since" | while read -r name; do
    [ -n "$name" ] || continue
    kctx -n kube-system delete secret "$name" --ignore-not-found >/dev/null
  done
cleanup_question "$QID"
question_state_clear "$QID"
