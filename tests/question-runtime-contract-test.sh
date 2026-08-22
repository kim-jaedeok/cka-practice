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

printf 'question runtime contract tests: PASS\n'
