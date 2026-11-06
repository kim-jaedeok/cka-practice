#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-08

EXTS08_DATA="$CKA_STATE_DIR/question-data/ex-ts-08"

exts08_stuck_uid() {
  [ -s "$EXTS08_DATA/stuck-job-uid" ] \
    || { grade_invalid "ex-ts-08 baseline stuck-job-uid missing" || true; return 2; }
  tr -d '\r\n' < "$EXTS08_DATA/stuck-job-uid"
}

exts08_cronjob_check() { # <mode>
  local json
  json="$(kctx -n nightly-ops get cronjob db-vacuum -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
mode = sys.argv[1]
spec = json.load(sys.stdin)["spec"]
job = spec.get("jobTemplate", {}).get("spec", {})
cs = job.get("template", {}).get("spec", {}).get("containers", [])
c = cs[0] if len(cs) == 1 else {}
if mode == "unchanged":
    ok = (spec.get("schedule") == "*/1 * * * *"
          and spec.get("concurrencyPolicy") == "Forbid"
          and spec.get("suspend") is not True
          and c.get("image") == "busybox:1.36"
          and c.get("command", []) + c.get("args", []) == [
              "sh", "-c", "echo \"vacuum started\"; sleep 3; echo \"vacuum complete\""])
elif mode == "deadline":
    value = job.get("activeDeadlineSeconds")
    ok = isinstance(value, int) and 1 <= value <= 120
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1"
}

# The hanging run is gone or has finished; it no longer blocks the schedule.
exts08_stuck_cleared() {
  local uid
  uid="$(exts08_stuck_uid)" || return $?
  kctx -n nightly-ops get jobs -o json 2>/dev/null | python3 -c '
import json, sys
uid = sys.argv[1]
for job in json.load(sys.stdin)["items"]:
    if job["metadata"]["uid"] != uid:
        continue
    done = any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True"
               for c in job.get("status", {}).get("conditions", []))
    active = job.get("status", {}).get("active", 0)
    raise SystemExit(0 if done and not active else 1)
raise SystemExit(0)
' "$uid"
}

# Another Job controlled or created from the CronJob completed successfully.
exts08_new_run_complete() {
  local uid
  uid="$(exts08_stuck_uid)" || return $?
  kctx -n nightly-ops get jobs -o json 2>/dev/null | python3 -c '
import json, sys
uid = sys.argv[1]
for job in json.load(sys.stdin)["items"]:
    meta = job["metadata"]
    if meta["uid"] == uid:
        continue
    owned = any(r.get("kind") == "CronJob" and r.get("name") == "db-vacuum"
                for r in meta.get("ownerReferences", []))
    done = any(c.get("type") == "Complete" and c.get("status") == "True"
               for c in job.get("status", {}).get("conditions", []))
    if owned and done:
        raise SystemExit(0)
raise SystemExit(1)
' "$uid"
}

_python3_require || true

criterion 1 "CronJob schedule, concurrencyPolicy, suspend and container are unchanged" \
  "exts08_cronjob_check unchanged"

criterion 1 "the hanging Job no longer runs" \
  "exts08_stuck_cleared"

criterion 2 "Jobs from the CronJob are stopped after at most 120 seconds" \
  "exts08_cronjob_check deadline"

criterion 2 "a new Job from CronJob db-vacuum completed successfully" \
  "exts08_new_run_complete"

grade_finish
