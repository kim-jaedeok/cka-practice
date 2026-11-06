#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-06

EXWL06_DATA="$CKA_STATE_DIR/question-data/ex-wl-06"

exwl06_uid() { # <ordinal>
  [ -s "$EXWL06_DATA/kv-$1-uid" ] \
    || { grade_invalid "ex-wl-06 baseline kv-$1-uid missing" || true; return 2; }
  tr -d '\r\n' < "$EXWL06_DATA/kv-$1-uid"
}

exwl06_pod_is() { # <ordinal> <image> <same-uid yes|no>
  local json uid update_rev
  uid="$(exwl06_uid "$1")" || return $?
  json="$(kctx -n quorum get pod "kv-$1" -o json 2>/dev/null)" || return 1
  update_rev="$(kctx -n quorum get sts kv -o jsonpath='{.status.updateRevision}' 2>/dev/null)"
  printf '%s' "$json" | python3 -c '
import json, sys
image, same, uid, update_rev = sys.argv[1:5]
pod = json.load(sys.stdin)
cs = pod["spec"]["containers"]
ready = any(c.get("type") == "Ready" and c.get("status") == "True"
            for c in pod.get("status", {}).get("conditions", []))
ok = (len(cs) == 1 and cs[0].get("image") == image and ready
      and not pod["metadata"].get("deletionTimestamp"))
if same == "yes":
    ok = ok and pod["metadata"]["uid"] == uid
    ok = ok and all(s.get("restartCount", 0) == 0
                    for s in pod.get("status", {}).get("containerStatuses", []))
else:
    ok = ok and pod["metadata"].get("labels", {}).get("controller-revision-hash") == update_rev
raise SystemExit(0 if ok else 1)
' "$2" "$3" "$uid" "$update_rev"
}

exwl06_strategy() {
  jp_eq sts kv quorum '{.spec.updateStrategy.type}' RollingUpdate \
    && jp_eq sts kv quorum '{.spec.updateStrategy.rollingUpdate.partition}' 2
}

_python3_require || true

criterion 2 "StatefulSet kv uses a RollingUpdate partition of 2" \
  "exwl06_strategy"

criterion 1 "the Pod template of kv runs nginx:1.29" \
  "jp_eq sts kv quorum '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 2 "kv-2 runs the updated revision with nginx:1.29 and is Ready" \
  "exwl06_pod_is 2 nginx:1.29 no"

criterion 2 "kv-0 and kv-1 were never replaced or restarted and still run nginx:1.28" \
  "exwl06_pod_is 0 nginx:1.28 yes && exwl06_pod_is 1 nginx:1.28 yes"

grade_finish
