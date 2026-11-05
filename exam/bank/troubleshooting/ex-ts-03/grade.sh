#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-03

EXTS03_DATA="$CKA_STATE_DIR/question-data/ex-ts-03"
EXTS03_FILE="$CKA_WORK_DIR/ex-ts-03/job-error.log"

exts03_baseline() { # <name>
  [ -s "$EXTS03_DATA/$1" ] \
    || { grade_invalid "ex-ts-03 baseline $1 missing" || true; return 2; }
  tr -d '\r\n' < "$EXTS03_DATA/$1"
}

# The file holds exactly the one error line (a trailing newline is optional).
exts03_error_file() {
  [ -f "$EXTS03_FILE" ] || return 1
  python3 - "$EXTS03_FILE" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
lines = [line.rstrip() for line in text.splitlines() if line.strip()]
expected = "FATAL: settings file /etc/report/report.conf is missing (code RPT-417)"
raise SystemExit(0 if lines == [expected] else 1)
PY
}

exts03_configmap_unchanged() {
  local expected current
  expected="$(exts03_baseline configmap-fingerprint)" || return $?
  current="$(kctx -n reports get configmap report-config -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(
    json.dumps(obj.get("data", {}), sort_keys=True).encode()).hexdigest())
')" || return 1
  [ "$current" = "$expected" ]
}

exts03_process_unchanged() {
  local expected current
  expected="$(exts03_baseline process-fingerprint)" || return $?
  current="$(kctx -n reports get job nightly-report -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
cs = obj["spec"]["template"]["spec"]["containers"]
c = cs[0] if len(cs) == 1 else {}
print(hashlib.sha256(json.dumps(
    [c.get("image"), c.get("command", []) + c.get("args", [])]).encode()).hexdigest())
')" || return 1
  [ "$current" = "$expected" ]
}

exts03_job_complete() {
  jp_eq job nightly-report reports '{.status.conditions[?(@.type=="Complete")].status}' True
}

# A succeeded Pod of the Job printed the values read from the ConfigMap.
exts03_report_output() {
  local pods pod
  pods="$(kctx -n reports get pods -l job-name=nightly-report \
    --field-selector=status.phase=Succeeded -o name 2>/dev/null)" || return 1
  for pod in $pods; do
    kctx -n reports logs "$pod" 2>/dev/null \
      | grep -Fxq 'report generated format=csv range=24h' && return 0
  done
  return 1
}

_python3_require || true

criterion 2 "job-error.log contains exactly the failed container's error line" \
  "exts03_error_file"

criterion 1 "ConfigMap report-config is unchanged" \
  "exts03_configmap_unchanged"

criterion 1 "Job nightly-report keeps its image and command" \
  "exts03_process_unchanged"

criterion 2 "Job nightly-report is Complete" \
  "exts03_job_complete"

criterion 1 "실측: the succeeded Pod printed the ConfigMap settings" \
  "exts03_report_output"

grade_finish
