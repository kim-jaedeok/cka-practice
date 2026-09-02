#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cka-question-runtime-test.XXXXXX")"
LOG="$TMP_ROOT/calls"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

err() { printf '%s\n' "$*" >&2; }
meta_get() { sed -n "s/^$2:[[:space:]]*//p" "$1/meta.yaml" | head -1; }

# shellcheck source=../lib/question-runtime.sh
source "$ROOT/lib/question-runtime.sh"

runtime_scripts_have_metadata_deadlines() {
  local runtime="$ROOT/lib/question-runtime.sh" body
  body="$(sed -n '/^_question_runtime_run_script()/,/^}/p' "$runtime")" || return 1
  grep -Fq 'meta_get "$qdir" setup_timeout_seconds' <<<"$body" \
    && grep -Fq 'QUESTION_RUNTIME_DEFAULT_SCRIPT_TIMEOUT_SECONDS' <<<"$body" \
    && grep -Fq 'timeout --foreground --kill-after=5s "${timeout_seconds}s" bash "$script"' \
      <<<"$body"
}
runtime_scripts_have_metadata_deadlines || {
  printf 'question setup/teardown process deadline contract is missing\n' >&2
  exit 1
}

held_lifecycle_lock_keeps_prepare_failure_cleanup_bounded() (
  set -euo pipefail
  local case_root="$TMP_ROOT/held-lock" qdir="$TMP_ROOT/held-lock-question"
  local holder="" rc=0 elapsed cleanup_rc=0 cleanup_elapsed before after role first_fd
  mkdir -p "$case_root" "$qdir"
  export CKA_CELL_RUNTIME_DIR="$case_root/runtime"
  export CKA_STATE_DIR="$case_root/state"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  export CKA_ENABLE_DISPOSABLE_CELLS=1
  export CKA_CELL_LOCK_WAIT_SECONDS=1
  # shellcheck source=../lib/cell.sh
  source "$ROOT/lib/cell.sh"
  cell_runtime_init
  mkdir -m 0700 "$CKA_STATE_DIR" "$(cell_state_dir ca-09)"

  CELL_RUN_ID=0123456789abcdef0123456789abcdef
  CELL_QID=ca-09
  CELL_PROFILE=operator-cell
  CELL_CLUSTER_NAME=cka-cell-ca-09-0123456789ab
  CELL_NETWORK_NAME="$CELL_CLUSTER_NAME"
  CELL_NETWORK_ID=PENDING
  CELL_STATUS=PREPARING
  declare -gA CELL_CONTAINER_IDS=()
  _cell_volume_arrays_init
  while IFS= read -r role; do
    CELL_VOLUME_COUNTS[$role]=0
  done < <(cell_expected_roles "$CELL_PROFILE")
  _cell_manifest_write ca-09
  printf 'ca-09\n' > "$(cell_selection_path)"
  chmod 0600 "$(cell_selection_path)"
  before="$(sha256sum "$(cell_manifest_path ca-09)" | awk '{print $1}')"
  : > "$case_root/docker.log"

  printf '%s\n' \
    'id: ca-09' \
    'environment: operator-cell' \
    'setup_timeout_seconds: 1' > "$qdir/meta.yaml"
  : > "$qdir/setup.sh"
  : > "$qdir/grade.sh"
  : > "$qdir/teardown.sh"

  # The bounded base preparation has already expired. Any Docker call during
  # cleanup would prove mutation happened without acquiring the lifecycle lock.
  cell_prepare() { return 124; }
  _cell_docker() { printf '%s\n' "$*" >> "$case_root/docker.log"; return 99; }

  # A synchronous nested lifecycle helper in one Bash process reuses the
  # already-held exact lock instead of waiting on itself. Normal lifecycle
  # entry points are subshells, so explicitly release this test acquisition.
  CELL_LOCK_FD=1
  CELL_LOCK_OWNER_BASHPID="$BASHPID"
  _cell_lock
  [ -e /proc/self/fd/1 ]
  first_fd="$CELL_LOCK_FD"
  _cell_lock
  [ "$CELL_LOCK_FD" = "$first_fd" ]
  exec {CELL_LOCK_FD}>&-
  unset CELL_LOCK_FD CELL_LOCK_OWNER_BASHPID

  (
    exec 9> "$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
    flock --exclusive 9
    : > "$case_root/lock-held"
    while [ ! -e "$case_root/release-lock" ]; do sleep 0.05; done
  ) &
  holder=$!
  release_holder() {
    : > "$case_root/release-lock"
    if [ -n "$holder" ]; then
      wait "$holder" 2>/dev/null || true
      holder=""
    fi
  }
  trap release_holder EXIT
  for _ in {1..100}; do
    [ -e "$case_root/lock-held" ] && break
    sleep 0.05
  done
  [ -e "$case_root/lock-held" ] || return 1

  SECONDS=0
  question_runtime_start ca-09 "$qdir" > "$case_root/output" 2>&1 || rc=$?
  elapsed=$SECONDS
  SECONDS=0
  _question_runtime_cleanup_disposable ca-09 "$qdir" operator-cell \
    >> "$case_root/output" 2>&1 || cleanup_rc=$?
  cleanup_elapsed=$SECONDS
  release_holder
  trap - EXIT

  after="$(sha256sum "$(cell_manifest_path ca-09)" | awk '{print $1}')"
  [ "$rc" -eq 1 ] \
    && [ "$elapsed" -le 4 ] \
    && [ "$cleanup_rc" -eq 75 ] \
    && [ "$cleanup_elapsed" -le 4 ] \
    && [ "$before" = "$after" ] \
    && [ "$(cat "$(cell_selection_path)")" = ca-09 ] \
    && [ ! -s "$case_root/docker.log" ] \
    && grep -Fq 'cell lifecycle lock wait exceeded 1s (exit 75)' "$case_root/output" \
    && grep -Fq 'exact cell cleanup failed (exit 75)' "$case_root/output" \
    && grep -Fq '상태와 active-cell 선택을 보존했습니다' "$case_root/output"
)

held_lifecycle_lock_keeps_prepare_failure_cleanup_bounded || {
  printf 'held-lock prepare failure cleanup contract failed\n' >&2
  exit 1
}

# The public adapter must be backed by explicit mappings. A missing mapping
# must fail closed instead of silently selecting the shared cluster.
for mapping in \
  'ca-09:operator-cell' 'ca-13:operator-cell' \
  'sn-05:gateway-cell' 'st-06:csi-cell'; do
  grep -Fq "$mapping" "$ROOT/lib/cell.sh" || {
    printf 'missing stable cell mapping: %s\n' "$mapping" >&2
    exit 1
  }
done

record() { printf '%s\n' "$*" >> "$LOG"; }
require_cluster() { record require_cluster; return "${REQUIRE_CLUSTER_RC:-0}"; }
require_cluster_readonly() { record require_cluster_readonly; return "${REQUIRE_CLUSTER_READONLY_RC:-0}"; }
cleanup_question() { record "cleanup_question:$1"; }
cell_prepare() { record "cell_prepare:$1:$2"; return "${CELL_PREPARE_RC:-0}"; }
cell_activate() { record "cell_activate:$1:$2"; return "${CELL_ACTIVATE_RC:-0}"; }
cell_cleanup() { record "cell_cleanup:$1:$2"; return "${CELL_CLEANUP_RC:-0}"; }
_cell_cleanup_all_managed_locked() { record _cell_cleanup_all_managed_locked; return 0; }
cell_cleanup_all_managed() { record cell_cleanup_all_managed; return 0; }
cell_status() { record "cell_status:$1:$2"; return "${CELL_STATUS_RC:-0}"; }
cell_select() { record "cell_select:$1:$2"; return "${CELL_SELECT_RC:-0}"; }
cell_selection_clear() { record "cell_selection_clear:$1"; return 0; }
cell_selection_clear_current() { record cell_selection_clear_current; return 0; }
controller_cell_status() { record "controller_status:$1:$2"; return "${PROFILE_STATUS_RC:-0}"; }
controller_cell_cleanup() { record "controller_cleanup:$1:$2"; return 0; }
csi_cell_prepare() { record "csi_prepare:$1:$2"; return "${PROFILE_PREPARE_RC:-0}"; }
csi_cell_activate() { record "csi_activate:$1:$2"; return "${PROFILE_ACTIVATE_RC:-0}"; }
csi_cell_status() { record "csi_status:$1:$2"; return 0; }
csi_cell_cleanup() { record "csi_cleanup:$1:$2"; return 0; }

_question_runtime_run_script() {
  record "script:$2"
  if [ "$1" = "$q_kubeadm" ] && [ "$2" = setup.sh ]; then
    [ "${CKA_ENABLE_DISPOSABLE_CELLS:-}" = 1 ] \
      && [ "${CKA_ENABLE_KUBEADM_CELLS:-}" = 1 ] || return 1
  fi
  [ "${FAIL_SCRIPT:-}" != "$2" ]
}

make_question() { # <name> [environment]
  local name="$1" environment="${2:-}" qdir
  qdir="$TMP_ROOT/$name"
  mkdir -p "$qdir"
  printf 'id: %s\n' "$name" > "$qdir/meta.yaml"
  [ -z "$environment" ] || printf 'environment: %s\n' "$environment" >> "$qdir/meta.yaml"
  : > "$qdir/setup.sh"
  : > "$qdir/grade.sh"
  : > "$qdir/teardown.sh"
  printf '%s\n' "$qdir"
}

reset_case() {
  : > "$LOG"
  unset REQUIRE_CLUSTER_RC REQUIRE_CLUSTER_READONLY_RC \
    CELL_PREPARE_RC CELL_ACTIVATE_RC CELL_CLEANUP_RC \
    CELL_STATUS_RC PROFILE_STATUS_RC PROFILE_PREPARE_RC PROFILE_ACTIVATE_RC \
    CELL_SELECT_RC FAIL_SCRIPT
}

expect_log() {
  local expected="$1" actual
  actual="$(cat "$LOG")"
  if [ "$actual" != "$expected" ]; then
    printf 'unexpected call sequence\nexpected:\n%s\nactual:\n%s\n' \
      "$expected" "$actual" >&2
    exit 1
  fi
}

# Missing metadata is the shared KIND path and preserves the old start/grade
# behavior without touching any disposable-cell function.
q_kubeadm=""
q_shared="$(make_question ts-01)"
reset_case
question_runtime_start ts-01 "$q_shared"
expect_log $'require_cluster\nscript:setup.sh\ncell_selection_clear_current'

reset_case
question_runtime_grade ts-01 "$q_shared"
expect_log 'script:grade.sh'

reset_case
question_runtime_cleanup ts-01 "$q_shared"
expect_log $'require_cluster_readonly\nscript:teardown.sh'

# An individual recovery drill owns restoration of the shared cluster fault it
# creates. Its setup/teardown must run even while the generic API precheck is
# unavailable; the scripts perform their own bounded recovery validation.
q_recovery="$(make_question ts-13)"
printf 'mode: individual-only\n' >> "$q_recovery/meta.yaml"
reset_case
REQUIRE_CLUSTER_RC=99
question_runtime_start ts-13 "$q_recovery"
expect_log $'script:setup.sh\ncell_selection_clear_current'

reset_case
REQUIRE_CLUSTER_READONLY_RC=99
question_runtime_cleanup ts-13 "$q_recovery"
expect_log 'script:teardown.sh'

# kubeadm setup owns construction.  Only after setup succeeds may the runtime
# export its verified context.
q_kubeadm="$(make_question ca-12 kubeadm-bootstrap)"
reset_case
question_runtime_start ca-12 "$q_kubeadm"
expect_log $'script:setup.sh\ncell_activate:ca-12:kubeadm-bootstrap\ncell_select:ca-12:kubeadm-bootstrap'

# Controller cells are allocated/activated before setup; controller profile
# setup remains inside the independently runnable question setup script.
q_operator="$(make_question ca-09 operator-cell)"
reset_case
question_runtime_start ca-09 "$q_operator"
expect_log $'cell_prepare:ca-09:operator-cell\ncell_activate:ca-09:operator-cell\ncell_select:ca-09:operator-cell\nscript:setup.sh'

# CSI must preload/validate the locked profile before publishing the exercise.
q_csi="$(make_question st-06 csi-cell)"
reset_case
question_runtime_start st-06 "$q_csi"
expect_log $'cell_prepare:st-06:csi-cell\ncell_activate:st-06:csi-cell\ncell_select:st-06:csi-cell\ncsi_prepare:st-06:csi-cell\ncsi_activate:st-06:csi-cell\nscript:setup.sh'

# Grading reactivates immutable ownership without restoring the controller
# baseline that the candidate was asked to change.
reset_case
question_runtime_grade ca-09 "$q_operator"
expect_log $'cell_activate:ca-09:operator-cell\ncell_select:ca-09:operator-cell\nscript:grade.sh'

reset_case
question_runtime_grade st-06 "$q_csi"
expect_log $'cell_activate:st-06:csi-cell\ncell_select:st-06:csi-cell\ncsi_activate:st-06:csi-cell\nscript:grade.sh'

# Explicit cleanup orders profile/question cleanup before immutable disposal.
reset_case
question_runtime_cleanup ca-09 "$q_operator"
expect_log $'cell_status:ca-09:operator-cell\ncell_activate:ca-09:operator-cell\ncell_select:ca-09:operator-cell\ncontroller_cleanup:ca-09:operator-cell\nscript:teardown.sh\ncell_cleanup:ca-09:operator-cell\ncell_selection_clear:ca-09'

# Reset disposes the prior cell, then creates a fresh one.
reset_case
question_runtime_reset st-06 "$q_csi"
expect_log $'cell_status:st-06:csi-cell\ncell_activate:st-06:csi-cell\ncell_select:st-06:csi-cell\ncsi_cleanup:st-06:csi-cell\nscript:teardown.sh\ncell_cleanup:st-06:csi-cell\ncell_selection_clear:st-06\ncell_prepare:st-06:csi-cell\ncell_activate:st-06:csi-cell\ncell_select:st-06:csi-cell\ncsi_prepare:st-06:csi-cell\ncsi_activate:st-06:csi-cell\nscript:setup.sh'

# A failed base-cell prepare is cleaned best-effort and never reaches shared
# cluster repair or the question setup script.
reset_case
CELL_PREPARE_RC=1
CELL_STATUS_RC=1
if question_runtime_start ca-09 "$q_operator"; then
  printf 'failed prepare unexpectedly succeeded\n' >&2
  exit 1
fi
expect_log $'cell_prepare:ca-09:operator-cell\ncell_status:ca-09:operator-cell\ncell_cleanup:ca-09:operator-cell\ncell_selection_clear:ca-09'

# GNU timeout reports 124 when the bounded prepare window expires. The runner
# treats that start failure exactly like any other partial PREPARING state and
# still attempts exact immutable cleanup before releasing selection state.
reset_case
CELL_PREPARE_RC=124
CELL_STATUS_RC=1
if question_runtime_start ca-09 "$q_operator"; then
  printf 'timed-out prepare unexpectedly succeeded\n' >&2
  exit 1
fi
expect_log $'cell_prepare:ca-09:operator-cell\ncell_status:ca-09:operator-cell\ncell_cleanup:ca-09:operator-cell\ncell_selection_clear:ca-09'

# If the new cell cannot be activated, teardown/profile hooks are skipped so
# they cannot inherit the shared context; immutable cleanup remains allowed.
reset_case
CELL_ACTIVATE_RC=1
if question_runtime_start ca-09 "$q_operator"; then
  printf 'failed activation unexpectedly succeeded\n' >&2
  exit 1
fi
expect_log $'cell_prepare:ca-09:operator-cell\ncell_activate:ca-09:operator-cell\ncell_status:ca-09:operator-cell\ncell_activate:ca-09:operator-cell\ncell_cleanup:ca-09:operator-cell\ncell_selection_clear:ca-09'

# A kubeadm setup failure also invokes immutable cleanup even when the cell has
# not reached READY and therefore cannot be activated.
reset_case
FAIL_SCRIPT=setup.sh
CELL_STATUS_RC=1
if question_runtime_start ca-12 "$q_kubeadm"; then
  printf 'failed kubeadm setup unexpectedly succeeded\n' >&2
  exit 1
fi
expect_log $'script:setup.sh\ncell_status:ca-12:kubeadm-bootstrap\ncell_cleanup:ca-12:kubeadm-bootstrap\ncell_selection_clear:ca-12'

# Unknown metadata fails closed before either execution path is touched.
q_unknown="$(make_question ca-99 unknown-cluster)"
reset_case
if question_runtime_start ca-99 "$q_unknown" >/dev/null 2>&1; then
  printf 'unknown environment unexpectedly succeeded\n' >&2
  exit 1
fi
expect_log ''

# `cluster down` uses the cell library's batch cleanup API rather than running
# question teardown scripts.  Exercise that API with real journal parsing and
# mocked immutable-object preflight/destruction boundaries so this stays
# Docker- and Kubernetes-free.
managed_cell_batch_cleanup_is_atomic_before_destroy() (
  set -euo pipefail
  local suite_root="$TMP_ROOT/all-managed" actual
  local saved_lock_definition

  export CKA_CELL_RUNTIME_DIR="$suite_root/bootstrap/cells"
  export CKA_STATE_DIR="$suite_root/bootstrap/state"
  export CKA_CELL_ALLOW_NON_NATIVE_STATE=1
  export CKA_ENABLE_DISPOSABLE_CELLS=1
  mkdir -p "$CKA_CELL_RUNTIME_DIR" "$CKA_STATE_DIR"
  chmod 0700 "$CKA_CELL_RUNTIME_DIR"

  # shellcheck source=../lib/cell.sh
  source "$ROOT/lib/cell.sh"
  declare -F cell_cleanup_all_managed >/dev/null || {
    printf 'cell_cleanup_all_managed API is missing\n' >&2
    return 1
  }
  saved_lock_definition="$(declare -f _cell_lock \
    | sed '1s/_cell_lock/_cell_lock_contract_real/')" || return 1
  eval "$saved_lock_definition"

  batch_record() { printf '%s\n' "$*" >> "$BATCH_LOG"; }

  # The public batch owns one lifecycle lock. Destructive work is represented
  # by an exact direct-child removal only after every preflight has succeeded.
  _cell_lock() { batch_record lock; }
  _cell_lock_is_owned() { :; }
  _cell_preflight_destroy() {
    batch_record "preflight:$1"
    [ "$1" != "${BATCH_PREFLIGHT_FAIL:-}" ]
  }
  _cell_prepare_destroy_locked() {
    batch_record "prepare:$1"
    [ "${2:-}" = 1 ] || return 69
    cell_manifest_load "$1" || return 1
    _cell_preflight_destroy "$1"
  }
  _cell_managed_inventory_preflight_locked() { batch_record inventory; }
  _cell_destroy_locked() {
    local qid="$1" state_dir
    batch_record "destroy:$qid"
    [ "${2:-}" = 1 ] || return 69
    [ "$qid" != "${BATCH_DESTROY_FAIL:-}" ] || return 68
    state_dir="$(cell_state_dir "$qid")" || return 1
    rm -f -- "$state_dir/manifest"
    rmdir -- "$state_dir"
  }

  # Any use of question cleanup would re-enter teardown/workdir/state handling
  # and violate the host-level shutdown contract.
  question_runtime_cleanup() { batch_record "forbidden:question-cleanup:$1"; return 97; }
  cleanup_question() { batch_record "forbidden:resource-cleanup:$1"; return 97; }
  workdir_clear() { batch_record "forbidden:workdir-clear:$1"; return 97; }
  state_clear() { batch_record "forbidden:state-clear:$1"; return 97; }

  batch_case_init() { # <case-name>
    local name="$1"
    CKA_CELL_RUNTIME_DIR="$suite_root/$name/cells"
    CKA_STATE_DIR="$suite_root/$name/state"
    BATCH_LOG="$suite_root/$name/calls"
    export CKA_CELL_RUNTIME_DIR CKA_STATE_DIR BATCH_LOG
    unset BATCH_PREFLIGHT_FAIL BATCH_DESTROY_FAIL
    mkdir -p "$CKA_CELL_RUNTIME_DIR" "$CKA_STATE_DIR"
    chmod 0700 "$CKA_CELL_RUNTIME_DIR"
    : > "$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
    chmod 0600 "$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
    : > "$BATCH_LOG"
  }

  batch_manifest() { # <qid> <profile> [recorded-qid]
    local qid="$1" profile="$2" recorded_qid="${3:-$1}" state_dir
    state_dir="$CKA_CELL_RUNTIME_DIR/$qid"
    mkdir -m 0700 -- "$state_dir"
    {
      printf '%s\n' \
        'schema=2' \
        'run_id=0123456789abcdef0123456789abcdef' \
        "question_id=$recorded_qid" \
        "profile=$profile" \
        "cluster_name=cka-cell-$qid-0123456789ab" \
        "network_name=cka-cell-$qid-0123456789ab" \
        'network_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'status=READY' \
        'container_cp1=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        'volume_count_cp1=0' \
        'container_worker1=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'volume_count_worker1=0'
    } > "$state_dir/manifest"
    chmod 0600 "$state_dir/manifest"
  }

  batch_select() { # <content...>
    printf '%s\n' "$@" > "$CKA_STATE_DIR/active-cell"
    chmod 0600 "$CKA_STATE_DIR/active-cell"
  }

  batch_no_mutation() {
    ! grep -Eq '^(destroy|forbidden):' "$BATCH_LOG"
  }

  # A regular lifecycle.lock is the sole non-journal root entry. Both cells
  # must finish non-destructive preparation before the first exact destroy;
  # successful completion clears a stale-but-well-formed selection.
  batch_case_init success
  batch_manifest ca-09 operator-cell
  batch_manifest sn-05 gateway-cell
  batch_select ts-99
  cell_cleanup_all_managed >/dev/null 2>&1 || return 1
  actual="$(cat "$BATCH_LOG")"
  [ "$actual" = $'lock\nprepare:ca-09\npreflight:ca-09\nprepare:sn-05\npreflight:sn-05\ninventory\ndestroy:ca-09\ndestroy:sn-05' ] \
    && [ -f "$CKA_CELL_RUNTIME_DIR/lifecycle.lock" ] \
    && [ ! -e "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ ! -e "$CKA_CELL_RUNTIME_DIR/sn-05" ] \
    && [ ! -e "$CKA_STATE_DIR/active-cell" ] || {
      printf 'managed cell success order/selection contract failed; calls:\n%s\n' "$actual" >&2
      return 1
    }

  # A later preflight failure must leave every managed object set undestroyed.
  # Production preparation may durably recover a PREPARING journal, but no
  # Docker removal may start until the whole set passes.
  batch_case_init failed-preflight
  batch_manifest ca-09 operator-cell
  batch_manifest sn-05 gateway-cell
  batch_select ca-09
  BATCH_PREFLIGHT_FAIL=sn-05
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted a failed preflight\n' >&2
    return 1
  fi
  actual="$(cat "$BATCH_LOG")"
  [ "$actual" = $'lock\nprepare:ca-09\npreflight:ca-09\nprepare:sn-05\npreflight:sn-05' ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/sn-05" ] \
    && [ -f "$CKA_STATE_DIR/active-cell" ] \
    && batch_no_mutation || {
      printf 'failed batch preflight mutated a cell; calls:\n%s\n' "$actual" >&2
      return 1
    }

  # Direct-child discovery is fail-closed and complete. An unknown entry sorted
  # after a valid qid must still prevent even the first journal preparation.
  batch_case_init unknown-child
  batch_manifest ca-09 operator-cell
  : > "$CKA_CELL_RUNTIME_DIR/zz-unknown"
  batch_select ca-09
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted an unknown runtime child\n' >&2
    return 1
  fi
  actual="$(cat "$BATCH_LOG")"
  [ "$actual" = lock ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -f "$CKA_CELL_RUNTIME_DIR/zz-unknown" ] \
    && [ -f "$CKA_STATE_DIR/active-cell" ] \
    && batch_no_mutation || {
      printf 'unknown runtime child was not fail-closed; calls:\n%s\n' "$actual" >&2
      return 1
    }

  # A syntactically valid direct child with a mismatched manifest may be
  # inspected, but no journal can be destroyed after the mismatch is found.
  batch_case_init mismatched-manifest
  batch_manifest ca-09 operator-cell
  batch_manifest sn-05 gateway-cell ca-09
  batch_select sn-05
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted a mismatched manifest identity\n' >&2
    return 1
  fi
  [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/sn-05" ] \
    && [ -f "$CKA_STATE_DIR/active-cell" ] \
    && batch_no_mutation || return 1

  # Active selection is part of the all-or-nothing validation. Malformed
  # content blocks preparation, while a valid stale qid is cleared on success.
  batch_case_init malformed-selection
  batch_manifest ca-09 operator-cell
  batch_select ca-09 sn-05
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted a malformed active selection\n' >&2
    return 1
  fi
  [ "$(cat "$BATCH_LOG")" = lock ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -f "$CKA_STATE_DIR/active-cell" ] \
    && batch_no_mutation || return 1

  # The selection file may be removed only through the exact canonical state
  # root. A linked parent must preserve both the foreign file and every cell.
  batch_case_init linked-selection-root
  batch_manifest ca-09 operator-cell
  mkdir -p "$suite_root/foreign-selection-state"
  printf 'ca-09\n' > "$suite_root/foreign-selection-state/active-cell"
  rmdir -- "$CKA_STATE_DIR"
  ln -s "$suite_root/foreign-selection-state" "$CKA_STATE_DIR"
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted a linked selection root\n' >&2
    return 1
  fi
  [ "$(cat "$BATCH_LOG")" = lock ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -f "$suite_root/foreign-selection-state/active-cell" ] \
    && batch_no_mutation || return 1

  batch_case_init stale-selection
  batch_select ts-99
  cell_cleanup_all_managed >/dev/null 2>&1 || return 1
  [ "$(cat "$BATCH_LOG")" = $'lock\ninventory' ] \
    && [ ! -e "$CKA_STATE_DIR/active-cell" ] || return 1

  # A stop after final-manifest unlink can leave only an empty qid directory.
  # With a clean global Docker inventory, that identity-pinned tombstone is
  # safe to remove and its stale active selection is cleared.
  batch_case_init empty-tombstone
  mkdir -m 0700 "$CKA_CELL_RUNTIME_DIR/ca-09"
  batch_select ca-09
  cell_cleanup_all_managed >/dev/null 2>&1 || return 1
  [ "$(cat "$BATCH_LOG")" = $'lock\ninventory' ] \
    && [ ! -e "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ ! -e "$CKA_STATE_DIR/active-cell" ] || return 1

  # The lifecycle lock name is special only for the exact regular file. Use
  # the real lock helper here to ensure a symlink is rejected before prepare.
  batch_case_init unsafe-lock
  batch_manifest ca-09 operator-cell
  batch_select ca-09
  rm -f -- "$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
  : > "$suite_root/foreign-lock"
  ln -s "$suite_root/foreign-lock" "$CKA_CELL_RUNTIME_DIR/lifecycle.lock"
  _cell_lock() { batch_record lock; _cell_lock_contract_real; }
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup accepted a symlinked lifecycle lock\n' >&2
    return 1
  fi
  [ "$(cat "$BATCH_LOG")" = lock ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ "$(cat "$suite_root/foreign-lock")" = '' ] \
    && batch_no_mutation || return 1

  # A destructive failure remains visible to the CLI and does not clear the
  # selection, so the shared cluster caller can abort without losing evidence.
  _cell_lock() { batch_record lock; }
  batch_case_init failed-destroy
  batch_manifest ca-09 operator-cell
  batch_manifest sn-05 gateway-cell
  batch_select ca-09
  BATCH_DESTROY_FAIL=ca-09
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup hid an exact destroy failure\n' >&2
    return 1
  fi
  grep -Fqx 'destroy:ca-09' "$BATCH_LOG" \
    && [ -d "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -f "$CKA_STATE_DIR/active-cell" ] \
    && ! grep -Fq 'forbidden:' "$BATCH_LOG" || return 1

  # If a later destroy fails after an earlier cell was removed, selection for
  # the successfully removed cell must already be gone. The failed cell and
  # its journal remain available for an exact retry.
  batch_case_init failed-second-destroy
  batch_manifest ca-09 operator-cell
  batch_manifest sn-05 gateway-cell
  batch_select ca-09
  BATCH_DESTROY_FAIL=sn-05
  if cell_cleanup_all_managed >/dev/null 2>&1; then
    printf 'managed cell cleanup hid a later exact destroy failure\n' >&2
    return 1
  fi
  [ ! -e "$CKA_CELL_RUNTIME_DIR/ca-09" ] \
    && [ -d "$CKA_CELL_RUNTIME_DIR/sn-05" ] \
    && [ ! -e "$CKA_STATE_DIR/active-cell" ] \
    && grep -Fqx 'destroy:sn-05' "$BATCH_LOG" \
    && ! grep -Fq 'forbidden:' "$BATCH_LOG" || return 1
)

managed_cell_batch_cleanup_is_atomic_before_destroy || {
  printf 'managed disposable cell batch cleanup contract failed\n' >&2
  exit 1
}

cluster_down_cleans_managed_cells_before_shared_cluster() {
  local body gate_body context_line lock_line managed_line loadbalancer_line delete_line provider_line guarded
  body="$(sed -n '/^cmd_cluster_down() (/,/^)/p' "$ROOT/cka")" || return 1
  gate_body="$(sed -n '/^infrastructure_gate_mode()/,/^}/p' "$ROOT/cka")" || return 1
  context_line="$(grep -n -m1 -F '[ "$CKA_CONTEXT" = "kind-$CKA_CLUSTER_NAME" ]' \
    <<<"$body" | cut -d: -f1)"
  lock_line="$(grep -n -m1 -F '_cell_lock' <<<"$body" | cut -d: -f1)"
  managed_line="$(grep -n -m1 -F '_cell_cleanup_all_managed_locked' <<<"$body" | cut -d: -f1)"
  loadbalancer_line="$(grep -n -m1 -F 'cloud_provider_kind_cleanup_cluster_loadbalancers' \
    <<<"$body" | cut -d: -f1)"
  delete_line="$(grep -n -m1 -F 'kind delete cluster --name' <<<"$body" | cut -d: -f1)"
  provider_line="$(grep -n -m1 -F 'cloud_provider_kind_stop_if_no_clusters' \
    <<<"$body" | cut -d: -f1)"
  [[ "$context_line" =~ ^[0-9]+$ ]] \
    && [[ "$lock_line" =~ ^[0-9]+$ ]] \
    && [[ "$managed_line" =~ ^[0-9]+$ ]] \
    && [[ "$loadbalancer_line" =~ ^[0-9]+$ ]] \
    && [[ "$delete_line" =~ ^[0-9]+$ ]] \
    && [[ "$provider_line" =~ ^[0-9]+$ ]] \
    && [ "$context_line" -lt "$lock_line" ] \
    && [ "$lock_line" -lt "$managed_line" ] \
    && [ "$managed_line" -lt "$loadbalancer_line" ] \
    && [ "$loadbalancer_line" -lt "$delete_line" ] \
    && [ "$delete_line" -lt "$provider_line" ] || return 1
  guarded="$(sed -n "${managed_line},$((managed_line + 1))p" <<<"$body")"
  grep -Fq '|| die' <<<"$guarded" \
    && grep -Fq 'down) printf '\''%s\n'\'' wait' <<<"$gate_body" \
    && ! grep -Fq 'cell_cleanup_all_managed ' <<<"$body" \
    && ! grep -Fq 'question_runtime_cleanup_all_disposable' <<<"$body"
}

cluster_down_cleans_managed_cells_before_shared_cluster || {
  printf 'cluster down managed-cell cleanup ordering contract failed\n' >&2
  exit 1
}

public_cli_creators_share_the_infrastructure_gate() {
  local gate_body exam_body ssh_body wrapper marker_root marker_rc=0
  gate_body="$(sed -n '/^infrastructure_gate_mode()/,/^}/p' "$ROOT/cka")" || return 1
  exam_body="$(sed -n '/^cmd_exam_entry()/,/^}/p' "$ROOT/cka")" || return 1
  ssh_body="$(sed -n '/^cmd_exam_ssh_entry()/,/^}/p' "$ROOT/cka")" || return 1
  wrapper="$(sed -n '/^# Re-exec mutating public commands/,/^cmd=/p' "$ROOT/cka")" || return 1
  grep -Fq 'start|grade|solution|reset|cleanup) printf '\''%s\n'\'' nowait' <<<"$gate_body" \
    && grep -Fq 'up|reset|doctor) printf '\''%s\n'\'' nowait' <<<"$gate_body" \
    && grep -Fq 'start) printf '\''%s\n'\'' nowait' <<<"$gate_body" \
    && grep -Fq 'prepare) printf '\''%s\n'\'' nowait' <<<"$gate_body" \
    && grep -Fq 'infrastructure_lock_exec "$infra_gate_mode"' <<<"$wrapper" \
    && grep -Fq 'infrastructure_gate_parent_holds_lock' <<<"$wrapper" \
    && grep -Fq 'CKA_INFRA_LOCK_ROOT="$CKA_INFRA_LOCK_CANONICAL_ROOT"' <<<"$wrapper" \
    && grep -Fq 'deny_if_exam_locked' <<<"$exam_body" \
    && grep -Fq 'deny_if_exam_locked' <<<"$ssh_body" || return 1

  # An inherited or caller-injected marker is not authority to bypass the
  # gate; only the direct flock parent holding this exact lock file is.
  marker_root="$TMP_ROOT/injected-gate-marker"
  mkdir -p "$marker_root/state"
  set +e
  env \
    CKA_INFRA_GATE_ACTIVE=1 \
    CKA_INFRA_LOCK_TEST_OVERRIDE=1 \
    CKA_INFRA_LOCK_ROOT=relative-path \
    CKA_STATE_DIR="$marker_root/state" \
    CKA_SSH_RUNNER_STATE_ROOT="$marker_root/ssh-state" \
    XDG_DATA_HOME="$marker_root/data" \
    bash "$ROOT/cka" solution ca-01 > "$marker_root/out" 2>&1
  marker_rc=$?
  set -e
  [ "$marker_rc" -ne 0 ] \
    && grep -Fq 'test infrastructure lock root는 임시 디렉터리 아래' "$marker_root/out"
}

public_cli_creators_share_the_infrastructure_gate || {
  printf 'public CLI infrastructure gate contract failed\n' >&2
  exit 1
}

cluster_down_mocked_cli_is_fail_closed() (
  set -euo pipefail
  local case_root rc=0 remaining
  case_root="$TMP_ROOT/cluster-down-cli"
  mkdir -p "$case_root/bin" "$case_root/cells" "$case_root/state"
  chmod 0700 "$case_root/cells"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "$*" >> "${CKA_FAKE_KIND_LOG:?}"' \
    'if [ "${1:-}" = delete ] && [ "${2:-}" = cluster ]; then exit 0; fi' \
    'if [ "${1:-}" = get ] && [ "${2:-}" = clusters ]; then echo foreign-kind; exit 0; fi' \
    'exit 64' > "$case_root/bin/kind"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}:${2:-}" in ps:-aq|info:*) exit 0 ;; *) exit 0 ;; esac' \
    > "$case_root/bin/docker"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$case_root/bin/kubectl"
  chmod 0755 "$case_root/bin/kind" "$case_root/bin/docker" "$case_root/bin/kubectl"
  : > "$case_root/kind.log"
  printf 'ca-09\n' > "$case_root/state/active-cell"
  chmod 0600 "$case_root/state/active-cell"

  set +e
  env \
    PATH="$case_root/bin:$PATH" \
    CKA_FAKE_KIND_LOG="$case_root/kind.log" \
    CKA_CONTEXT=kind-foreign \
    CKA_STATE_DIR="$case_root/state" \
    CKA_CELL_RUNTIME_DIR="$case_root/cells" \
    CKA_CELL_ALLOW_NON_NATIVE_STATE=1 \
    CKA_INFRA_LOCK_TEST_OVERRIDE=1 \
    CKA_INFRA_LOCK_ROOT="$case_root/infra" \
    CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1 \
    XDG_DATA_HOME="$case_root/data" \
    bash "$ROOT/cka" cluster down > "$case_root/context-failed.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    && [ -f "$case_root/state/active-cell" ] \
    && ! grep -Fq 'delete cluster' "$case_root/kind.log" || return 1

  : > "$case_root/cells/unknown-entry"

  set +e
  env \
    PATH="$case_root/bin:$PATH" \
    CKA_FAKE_KIND_LOG="$case_root/kind.log" \
    CKA_STATE_DIR="$case_root/state" \
    CKA_CELL_RUNTIME_DIR="$case_root/cells" \
    CKA_CELL_ALLOW_NON_NATIVE_STATE=1 \
    CKA_INFRA_LOCK_TEST_OVERRIDE=1 \
    CKA_INFRA_LOCK_ROOT="$case_root/infra" \
    CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1 \
    XDG_DATA_HOME="$case_root/data" \
    bash "$ROOT/cka" cluster down > "$case_root/failed.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    && [ -f "$case_root/cells/unknown-entry" ] \
    && [ -f "$case_root/state/active-cell" ] \
    && ! grep -Fq 'delete cluster' "$case_root/kind.log" || return 1

  rm -- "$case_root/cells/unknown-entry"
  : > "$case_root/kind.log"
  env \
    PATH="$case_root/bin:$PATH" \
    CKA_FAKE_KIND_LOG="$case_root/kind.log" \
    CKA_STATE_DIR="$case_root/state" \
    CKA_CELL_RUNTIME_DIR="$case_root/cells" \
    CKA_CELL_ALLOW_NON_NATIVE_STATE=1 \
    CKA_INFRA_LOCK_TEST_OVERRIDE=1 \
    CKA_INFRA_LOCK_ROOT="$case_root/infra" \
    CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1 \
    XDG_DATA_HOME="$case_root/data" \
    bash "$ROOT/cka" cluster down > "$case_root/success.out" 2>&1
  remaining="$(find "$case_root/cells" -mindepth 1 -maxdepth 1 \
    ! -name lifecycle.lock -print -quit)"
  [ -z "$remaining" ] \
    && [ -f "$case_root/cells/lifecycle.lock" ] \
    && [ ! -e "$case_root/state/active-cell" ] \
    && grep -Fqx 'delete cluster --name cka' "$case_root/kind.log" \
    && grep -Fq '요청한 클러스터 정리는 완료했습니다. 다른 KIND cluster가 남아 host-global Cloud Provider KIND만 계속 실행합니다.' \
      "$case_root/success.out" || {
        printf '%s\n' 'mocked cluster down success diagnostics:' >&2
        sed -n l "$case_root/kind.log" >&2
        sed -n l "$case_root/success.out" >&2
        return 1
      }
)

cluster_down_mocked_cli_is_fail_closed || {
  printf 'mocked cluster down fail-closed contract failed\n' >&2
  exit 1
}

printf 'question runtime contract tests: PASS\n'
