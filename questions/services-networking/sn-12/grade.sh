#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-12

ANSWER="$CKA_WORK_DIR/sn-12/ipam.txt"

# Read the IPAM type from the live node's first config file so the grader
# follows whatever CNI the cluster uses.
sn12_expected_ipam() {
  local conf
  _python3_require || return $?
  conf="$(node_exec_out cka-worker \
    'f=$(ls /etc/cni/net.d/*.conflist /etc/cni/net.d/*.conf 2>/dev/null | sort | head -n 1); cat "$f"')" || {
    grade_invalid "sn-12 could not read the cka-worker CNI configuration" || true
    return 2
  }
  printf '%s' "$conf" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
plugins = doc.get("plugins") or [doc]
types = [p["ipam"]["type"] for p in plugins if isinstance(p.get("ipam"), dict) and p["ipam"].get("type")]
if len(types) != 1:
    raise SystemExit(1)
print(types[0])
'
}

sn12_answer_matches() {
  local expected actual
  expected="$(sn12_expected_ipam)" || return $?
  actual="$(tr -d '[:space:]' < "$ANSWER" 2>/dev/null)" || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

sn12_cni_conf_unchanged() {
  local path="$CKA_STATE_DIR/question-data/sn-12/cni-conf-sha256" expected current
  [ -s "$path" ] \
    || { grade_invalid "sn-12 baseline CNI checksum missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(node_exec_out cka-worker 'cat /etc/cni/net.d/*.conflist' | sha256sum | awk '{print $1}')"
  [ "$current" = "$expected" ]
}

criterion 1 "ipam.txt가 존재하고 node의 CNI 설정이 그대로" \
  "file_exists \"\$ANSWER\" && sn12_cni_conf_unchanged"

criterion 3 "파일의 값이 CNI 설정의 IPAM plugin type과 같음" \
  "sn12_answer_matches"

grade_finish
