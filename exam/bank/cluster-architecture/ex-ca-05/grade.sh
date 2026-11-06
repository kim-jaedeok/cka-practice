#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-05

EXCA05_DATA="$CKA_STATE_DIR/question-data/ex-ca-05"
EXCA05_CP="$(cka_cp_node)"
EXCA05_SNAP=/var/lib/etcd-backup/pre-upgrade.db
EXCA05_FILE="$CKA_WORK_DIR/ex-ca-05/revision.txt"

exca05_baseline() { # <name>
  [ -s "$EXCA05_DATA/$1" ] \
    || { grade_invalid "ex-ca-05 baseline $1 missing" || true; return 2; }
  tr -d '\r\n' < "$EXCA05_DATA/$1"
}

exca05_tools() {
  node_exec "$EXCA05_CP" 'command -v etcdutl' \
    || { grade_invalid "etcdutl unavailable on $EXCA05_CP" || true; return 2; }
}

exca05_status_json() {
  exca05_tools || return $?
  node_exec_out "$EXCA05_CP" "etcdutl snapshot status $EXCA05_SNAP -w json"
}

exca05_snapshot_valid() {
  local json
  json="$(exca05_status_json)" || return $?
  printf '%s' "$json" | python3 -c '
import json, sys
s = json.loads(sys.stdin.read())
raise SystemExit(0 if s.get("revision", 0) > 0 and s.get("totalKey", 0) > 0 else 1)
'
}

exca05_snapshot_has_marker() {
  local marker
  marker="$(exca05_baseline marker)" || return $?
  node_exec "$EXCA05_CP" "grep -aqF '$marker' $EXCA05_SNAP"
}

exca05_revision_file() {
  local json expected actual
  [ -f "$EXCA05_FILE" ] || return 1
  json="$(exca05_status_json)" || return $?
  expected="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["revision"])')" \
    || return 1
  actual="$(tr -d '[:space:]' < "$EXCA05_FILE")"
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

exca05_etcd_untouched() {
  local expected current
  expected="$(exca05_baseline etcd-manifest-sha256)" || return $?
  current="$(node_exec_out "$EXCA05_CP" 'sha256sum /etc/kubernetes/manifests/etcd.yaml' | cut -d' ' -f1)"
  [ "$current" = "$expected" ] && pod_ready kube-system "etcd-$EXCA05_CP"
}

_python3_require || true

criterion 2 "a valid etcd snapshot exists at $EXCA05_SNAP" \
  "exca05_snapshot_valid"

criterion 2 "the snapshot was taken after ConfigMap cutover-plan was created" \
  "exca05_snapshot_has_marker"

criterion 2 "revision.txt holds the revision of that snapshot" \
  "exca05_revision_file"

criterion 1 "the etcd static Pod manifest is unchanged and etcd is Ready" \
  "exca05_etcd_untouched"

grade_finish
