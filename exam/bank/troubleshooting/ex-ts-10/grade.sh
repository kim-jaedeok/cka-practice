#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-10

EXTS10_DATA="$CKA_STATE_DIR/question-data/ex-ts-10"
EXTS10_CRD=workqueues.queue.example.io

exts10_baseline() { # <name>
  [ -s "$EXTS10_DATA/$1" ] \
    || { grade_invalid "ex-ts-10 baseline $1 missing" || true; return 2; }
  tr -d '\r\n' < "$EXTS10_DATA/$1"
}

exts10_namespace_gone() {
  local out
  out="$(kctx get namespace tenant-old -o name 2>&1)" && return 1
  printf '%s\n' "$out" | grep -q 'NotFound'
}

# A forced namespace removal leaves the namespaced objects in storage. They
# are still listed under the old namespace name.
exts10_no_leftovers() {
  local queues cms
  queues="$(kctx -n tenant-old get workqueues -o name 2>/dev/null)" || return 1
  cms="$(kctx -n tenant-old get configmap drain-state -o name 2>/dev/null || true)"
  [ -z "$queues" ] && [ -z "$cms" ]
}

exts10_crd_kept() {
  local expected
  expected="$(exts10_baseline crd-uid)" || return $?
  jp_eq crd "$EXTS10_CRD" - '{.metadata.uid}' "$expected"
}

exts10_live_kept() {
  local expected
  expected="$(exts10_baseline live-uid)" || return $?
  jp_eq workqueue billing-q tenant-live '{.metadata.uid}' "$expected" \
    && jp_eq workqueue billing-q tenant-live '{.metadata.finalizers[*]}' queue.example.io/drain \
    && [ -z "$(kctx -n tenant-live get workqueue billing-q -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
}

criterion 2 "namespace tenant-old is deleted" \
  "exts10_namespace_gone"

criterion 2 "no WorkQueue or drain-state ConfigMap is left behind in tenant-old" \
  "exts10_no_leftovers"

criterion 1 "the WorkQueue CRD was not deleted" \
  "exts10_crd_kept"

criterion 1 "WorkQueue billing-q in tenant-live is unchanged" \
  "exts10_live_kept"

grade_finish
