#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-11

ANSWER="$CKA_WORK_DIR/sn-11/egress-interface.txt"

# The expected interface comes from the node's live routing table, so the
# grader stays correct whichever overlay (IPIP, VXLAN, ...) the CNI uses.
sn11_expected_interface() {
  local ip route
  ip="$(_jp_get pod trainer-b fabric '{.status.podIP}')" || return 1
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  route="$(node_exec_out cka-worker "ip -4 route get $ip")" || {
    grade_invalid "sn-11 could not read the cka-worker routing table" || true
    return 2
  }
  sed -n 's/.* dev \([^ ]*\).*/\1/p' <<< "$route" | head -n 1
}

sn11_answer_matches() {
  local expected actual
  expected="$(sn11_expected_interface)" || return $?
  [ -n "$expected" ] || return 1
  actual="$(tr -d '[:space:]' < "$ANSWER" 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

criterion 1 "egress-interface.txt가 존재" \
  "file_exists \"\$ANSWER\""

criterion 3 "파일의 interface가 cka-worker에서 trainer-b로 가는 route의 interface와 같음" \
  "sn11_answer_matches"

grade_finish
