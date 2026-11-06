#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-st-03

EXST03_DATA="$CKA_STATE_DIR/question-data/ex-st-03"

exst03_new_claim() {
  kctx -n reports-store get pvc reports-v2 -o json 2>/dev/null | python3 -c '
import json, sys
pvc = json.load(sys.stdin)
spec = pvc["spec"]
ok = (pvc.get("status", {}).get("phase") == "Bound"
      and spec.get("storageClassName") == "standard"
      and spec.get("accessModes") == ["ReadWriteOnce"]
      and spec.get("resources", {}).get("requests", {}).get("storage") == "512Mi")
raise SystemExit(0 if ok else 1)
'
}

exst03_data_copied() {
  local expected actual
  [ -s "$EXST03_DATA/checksums" ] \
    || { grade_invalid "ex-st-03 baseline checksums missing" || true; return 2; }
  expected="$(cat "$EXST03_DATA/checksums")"
  # The files must come from the new claim, not from the old one.
  claim_mounted_at deploy report-server reports-store reports-v2 /data server || return 1
  deploy_ready reports-store report-server 1 || return 1
  actual="$(kctx -n reports-store exec deploy/report-server -c server -- sh -c \
    'cd /data && sha256sum q1.csv q2.csv archive/2025.csv' 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

exst03_old_kept() {
  jp_eq pvc reports-old reports-store '{.status.phase}' Bound \
    && [ -z "$(kctx -n reports-store get pvc reports-old -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
}

_python3_require || true

criterion 1 "PVC reports-v2 is Bound with StorageClass standard, ReadWriteOnce, 512Mi" \
  "exst03_new_claim"

criterion 1 "volume data of report-server uses reports-v2 at /data" \
  "claim_mounted_at deploy report-server reports-store reports-v2 /data server"

criterion 1 "report-server has 1 Ready replica" \
  "deploy_ready reports-store report-server 1"

criterion 2 "실측: report-server serves the same report files from the new volume" \
  "exst03_data_copied"

criterion 1 "PVC reports-old is kept" \
  "exst03_old_kept"

grade_finish
