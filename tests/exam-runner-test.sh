#!/usr/bin/env bash
# Cluster-free contract tests for the form planner and exam state/deadline logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANNER="$ROOT/exam/planner.sh"
TMP="$(mktemp -d)"
case "$TMP" in /tmp/*|/var/tmp/*) ;; *) printf 'unsafe temp path: %s\n' "$TMP" >&2; exit 1 ;; esac
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bash "$PLANNER" --seed contract-seed-a \
  --questions-out "$TMP/form-a1" --setup-order-out "$TMP/setup-a1"
bash "$PLANNER" --seed contract-seed-a \
  --questions-out "$TMP/form-a2" --setup-order-out "$TMP/setup-a2"
cmp -s "$TMP/form-a1" "$TMP/form-a2" || fail "same seed produced different forms"
cmp -s "$TMP/setup-a1" "$TMP/setup-a2" || fail "same seed produced different setup order"
pass "planner output is reproducible"

bash "$PLANNER" --validate "$TMP/form-a1"
[ "$(wc -l < "$TMP/form-a1" | tr -d ' ')" -eq 17 ] || fail "form does not contain 17 questions"
[ "$(sort -u "$TMP/form-a1" | wc -l | tr -d ' ')" -eq 17 ] || fail "form contains duplicate questions"
grep -qx 'ts-12' "$TMP/form-a1" && fail "shared-cluster form contains disabled ts-12"
grep -qx 'ts-05' "$TMP/form-a1" && fail "shared-cluster form contains disabled ts-05"
pass "generated form satisfies count, uniqueness, and compatibility contract"

cp "$ROOT/exam/forms/question-catalog.tsv" "$TMP/disposable-enabled.tsv"
sed -i 's/^ca-09|\(.*\)|false$/ca-09|\1|true/' "$TMP/disposable-enabled.tsv"
if CKA_FORM_CATALOG="$TMP/disposable-enabled.tsv" \
    bash "$PLANNER" --seed invalid-disposable >/dev/null 2>&1; then
  fail "planner accepted a disposable-cell question in the shared form catalog"
fi
pass "planner rejects enabled questions whose metadata requires a disposable cell"

cat > "$TMP/incompatible-form" <<'EOF'
ts-01
ts-02
ts-03
ts-04
ts-07
ca-01
ca-03
ca-05
ca-08
sn-02
sn-04
sn-07
wl-01
wl-02
wl-03
st-01
st-04
EOF
if bash "$PLANNER" --validate "$TMP/incompatible-form" >/dev/null 2>&1; then
  fail "planner accepted known-incompatible ca-05/sn-07 form"
fi
pass "planner rejects ca-05 with sn-07 ownerless-Pod setup"

# The clean-host SSH lifecycle uses this fixed seed.  Keep it reproducible and
# prove catalog changes cannot silently regenerate a conflicting 17-question
# form before the live validation reaches setup/solve.
bash "$ROOT/exam/ssh/gated-form.sh" --catalog-out "$TMP/ssh-catalog.tsv" >/dev/null
CKA_FORM_CATALOG="$TMP/ssh-catalog.tsv" bash "$PLANNER" \
  --seed ssh-supervised-live-v1 \
  --questions-out "$TMP/ssh-fixed-form" \
  --setup-order-out "$TMP/ssh-fixed-setup"
CKA_FORM_CATALOG="$TMP/ssh-catalog.tsv" bash "$PLANNER" \
  --validate "$TMP/ssh-fixed-form"
bash "$ROOT/exam/ssh/gated-form.sh" --verify-form "$TMP/ssh-fixed-form" >/dev/null
[ "$(wc -l < "$TMP/ssh-fixed-form" | tr -d ' ')" -eq 17 ] \
  || fail "fixed SSH seed did not produce 17 questions"
[ "$(sort -u "$TMP/ssh-fixed-form" | wc -l | tr -d ' ')" -eq 17 ] \
  || fail "fixed SSH seed produced duplicate questions"
if grep -qx ca-05 "$TMP/ssh-fixed-form" && grep -qx sn-07 "$TMP/ssh-fixed-form"; then
  fail "fixed SSH seed combined ca-05 with sn-07"
fi
pass "fixed SSH seed regenerates a unique compatible 17-question form"

export CKA_EXAM_SOURCE_ONLY=1
# shellcheck source=../exam/mock-exam.sh
source "$ROOT/exam/mock-exam.sh"
export CKA_INFRA_LOCK_TEST_OVERRIDE=1

(
  POD_FIXTURE='{"items":[{"metadata":{"namespace":"ns","name":"managed","ownerReferences":[{"controller":true}]}}]}'
  kctx() { printf '%s' "$POD_FIXTURE"; }
  node_has_only_managed_pods cka-worker || fail "managed Pod blocked a drain form"
  POD_FIXTURE='{"items":[{"metadata":{"namespace":"ns","name":"naked"}}]}'
  if node_has_only_managed_pods cka-worker >/dev/null 2>&1; then
    fail "unmanaged Pod was accepted on a drain target"
  fi
)
pass "drain runtime preflight rejects unmanaged Pods"

# Cluster-free cleanup contract: individual blocks override cleanup_question
# to exercise success/failure aggregation; Kubernetes residue checks are live-
# cluster coverage and are stubbed here.
verify_question_cleanup() { return 0; }
verify_cluster_cleanup_invariants() { return 0; }
verify_cluster_cleanup_invariants_bounded() { verify_cluster_cleanup_invariants "$1"; }
cleanup_question_bounded() { cleanup_question "$2"; }
verify_form_runtime_requirements() { return 0; }
require_cluster_readonly() { return 0; }
cluster_matches_version_lock() { return 0; }

lock_state="$TMP/atomic-lock-state"
(
  CKA_STATE_DIR="$lock_state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  acquire_exam_lock first
  printf 'first\n' >> "$TMP/lock-winners"
  sleep 1
) >/dev/null 2>&1 &
first_lock_pid=$!
for _ in $(seq 1 50); do
  [ -r "$lock_state/exam.lock/owner" ] && break
  sleep 0.02
done
[ -r "$lock_state/exam.lock/owner" ] || fail "first atomic lock owner was not published"
set +e
(
  CKA_STATE_DIR="$lock_state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  acquire_exam_lock second
  printf 'second\n' >> "$TMP/lock-winners"
) >/dev/null 2>&1
second_lock_rc=$?
set -e
wait "$first_lock_pid"
[ "$second_lock_rc" -ne 0 ] || fail "concurrent command acquired an already-held lock"
[ "$(cat "$TMP/lock-winners")" = first ] || fail "more than one concurrent lock winner was recorded"
[ ! -d "$lock_state/exam.lock" ] || fail "atomic lock directory remained after release"
pass "atomic owner publication permits exactly one concurrent lock holder"

stale_lock_state="$TMP/stale-lock-state"
mkdir -p "$stale_lock_state/exam.lock"
printf '99999999 stale-token\n' > "$stale_lock_state/exam.lock/owner"
stale_lock_candidate() (
  CKA_STATE_DIR="$stale_lock_state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  acquire_exam_lock stale-reclaimer
  printf '%s\n' "${BASHPID:-$$}" >> "$TMP/stale-lock-winners"
  sleep 1
)
set +e
stale_lock_candidate >/dev/null 2>&1 &
stale_pid_a=$!
stale_lock_candidate >/dev/null 2>&1 &
stale_pid_b=$!
wait "$stale_pid_a"; stale_rc_a=$?
wait "$stale_pid_b"; stale_rc_b=$?
set -e
stale_successes=0
[ "$stale_rc_a" -eq 0 ] && stale_successes=$((stale_successes + 1))
[ "$stale_rc_b" -eq 0 ] && stale_successes=$((stale_successes + 1))
[ "$stale_successes" -eq 1 ] || fail "stale lock reclaim produced $stale_successes winners"
[ "$(wc -l < "$TMP/stale-lock-winners" | tr -d ' ')" -eq 1 ] \
  || fail "stale lock reclaim published more than one owner"
[ ! -d "$stale_lock_state/exam.lock" ] || fail "stale lock directory remained after winner release"
pass "stale owner reclaim is serialized and ABA-safe"

(
  CKA_STATE_DIR="$TMP/deadline-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  mkdir -p "$EXAM_DIR"
  set_exam_state RUNNING

  real_now="$(date +%s)"
  printf '%s\n' "$((real_now + 3600))" > "$EXAM_DIR/deadline"
  export CKA_EXAM_NOW=9999999999
  [ "$(exam_now)" -ne 9999999999 ] || fail "production clock accepted CKA_EXAM_NOW spoof"
  acquire_exam_lock status
  sync_deadline_state
  [ "$(exam_state)" = RUNNING ] || fail "spoofed production clock sealed the exam"
  unlock_exam_command

  exam_now() { printf '%s\n' 100; }
  printf '100\n' > "$EXAM_DIR/deadline"
  acquire_exam_lock status
  sync_deadline_state
  [ "$(exam_state)" = SEALED ] || fail "deadline did not seal RUNNING exam"
  [ "$(cat "$EXAM_DIR/seal-reason")" = TIMEOUT ] || fail "deadline seal reason is not TIMEOUT"
  seal_exam SUBMITTED
  [ "$(cat "$EXAM_DIR/seal-reason")" = TIMEOUT ] || fail "second seal overwrote first seal reason"
  unlock_exam_command
  if score_is_pass 100 1 0; then
    fail "timed-out perfect score was accepted as pass"
  fi
  transition_state GRADING
  transition_state ARCHIVED
  [ "$(exam_state)" = ARCHIVED ] || fail "normal terminal state is not ARCHIVED"
)
pass "production clock rejects overrides; deadline sealing is locked and idempotent"
(
  CKA_STATE_DIR="$TMP/common-state"
  if exam_actions_locked; then fail "missing exam state was locked"; fi
  mkdir -p "$CKA_STATE_DIR/exam"
  printf 'BROKEN\n' > "$CKA_STATE_DIR/exam/state"
  exam_actions_locked || fail "corrupt exam state was not fail-closed"
  printf 'ARCHIVED\n' > "$CKA_STATE_DIR/exam/state"
  if exam_actions_locked; then fail "ARCHIVED exam state remained locked"; fi
)
pass "common exam action guard fails closed on corrupt state"

(
  CKA_SSH_RUNNER_STATE_ROOT="$TMP/supervised-guard"
  if supervised_exam_actions_locked; then
    fail "missing supervised runner root was locked"
  fi
  mkdir -m 0700 "$CKA_SSH_RUNNER_STATE_ROOT"
  if supervised_exam_actions_locked; then
    fail "inactive supervised runner root was locked"
  fi
  : > "$CKA_SSH_RUNNER_STATE_ROOT/active"
  supervised_exam_actions_locked \
    || fail "active supervised runner was not locked"
  rm -- "$CKA_SSH_RUNNER_STATE_ROOT/active"
  mv -- "$CKA_SSH_RUNNER_STATE_ROOT" "$TMP/supervised-guard-real"
  ln -s "$TMP/supervised-guard-real" "$CKA_SSH_RUNNER_STATE_ROOT"
  supervised_exam_actions_locked \
    || fail "unsafe supervised runner root was not fail-closed"
)
pass "supervised exam action guard blocks active or unsafe runner state"

(
  mkdir -m 0700 "$TMP/infrastructure-gate-target"
  ln -s "$TMP/infrastructure-gate-target" "$TMP/infrastructure-gate-link"
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate-link"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  if infrastructure_lock_run nowait true >/dev/null 2>&1; then
    fail "infrastructure lock accepted a symlinked state root"
  fi
  rm -- "$TMP/infrastructure-gate-link"
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate-target"
  mkfifo "$CKA_INFRA_LOCK_ROOT/infrastructure.lock"
  if infrastructure_lock_run nowait true >/dev/null 2>&1; then
    fail "infrastructure lock accepted a non-regular lock file"
  fi
)
pass "host infrastructure gate rejects unsafe state and lock paths"

(
  mkdir -m 0700 "$TMP/infrastructure-hardlink-gate"
  printf 'do-not-touch\n' > "$TMP/infrastructure-hardlink-target"
  chmod 0600 "$TMP/infrastructure-hardlink-target"
  ln "$TMP/infrastructure-hardlink-target" \
    "$TMP/infrastructure-hardlink-gate/infrastructure.lock"
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-hardlink-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  if infrastructure_lock_run nowait true >/dev/null 2>&1; then
    fail "infrastructure gate accepted a hardlinked lock file"
  fi
  [ "$(cat "$TMP/infrastructure-hardlink-target")" = do-not-touch ] \
    || fail "infrastructure lock validation modified a hardlink target"
)
pass "host infrastructure gate rejects hardlinked locks without mutation"

infra_holder=""
infra_signal_guard=""
cleanup_infra_holder() {
  if [ -n "$infra_holder" ]; then
    printf 'release\n' > "$TMP/infrastructure-lock-release" 2>/dev/null \
      || kill "$infra_holder" 2>/dev/null || true
    wait "$infra_holder" 2>/dev/null || true
  fi
  if [ -n "$infra_signal_guard" ]; then
    kill -TERM "$infra_signal_guard" 2>/dev/null || true
    wait "$infra_signal_guard" 2>/dev/null || true
  fi
}
trap 'cleanup_infra_holder; rm -rf -- "$TMP"' EXIT
mkfifo "$TMP/infrastructure-lock-release"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  CKA_INFRA_LOCK_WAIT_SECONDS=1
  infrastructure_lock_run wait bash -c '
    : > "$1/infrastructure-lock-held"
    exec 8<> "$1/infrastructure-lock-release"
    IFS= read -r _ <&8
  ' bash "$TMP"
) &
infra_holder=$!
for _ in $(seq 1 100); do
  [ -e "$TMP/infrastructure-lock-held" ] && break
  sleep 0.01
done
[ -e "$TMP/infrastructure-lock-held" ] || fail "infrastructure lock holder did not start"
set +e
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  CKA_INFRA_LOCK_WAIT_SECONDS=1
  infrastructure_lock_run wait true
) >/dev/null 2>&1
infra_contender_rc=$?
set -e
[ "$infra_contender_rc" -eq "$CKA_INFRA_LOCK_TIMEOUT_RC" ] \
  || fail "infrastructure lock contention did not return the timeout status"
[ "$(stat -c %a "$TMP/infrastructure-gate")" = 700 ] \
  || fail "infrastructure lock root permissions are not 0700"
[ "$(stat -c %a "$TMP/infrastructure-gate/infrastructure.lock")" = 600 ] \
  || fail "infrastructure lock permissions are not 0600"
cleanup_infra_holder
infra_holder=""
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  CKA_INFRA_LOCK_WAIT_SECONDS=1
  umask 022
  infrastructure_lock_run wait true
  [ "$(umask)" = 0022 ] || fail "infrastructure lock preparation leaked its umask"
) || fail "infrastructure lock was not reusable after release"
pass "host infrastructure mutations use one bounded exclusive gate"

mkfifo "$TMP/infrastructure-descendant-release"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run wait bash -c '
    (
      exec 8<> "$1/infrastructure-descendant-release"
      : > "$1/infrastructure-descendant-ready"
      IFS= read -r _ <&8
    ) &
  ' bash "$TMP"
)
for _ in $(seq 1 100); do
  [ -e "$TMP/infrastructure-descendant-ready" ] && break
  sleep 0.01
done
[ -e "$TMP/infrastructure-descendant-ready" ] \
  || fail "infrastructure lock descendant did not start"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run nowait true
) || fail "a long-lived descendant inherited the infrastructure lock"
printf 'release\n' > "$TMP/infrastructure-descendant-release"
pass "infrastructure lock descriptor is closed before long-lived descendants"

(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-signal-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_exec wait bash -c '
    trap "exit 143" TERM INT HUP
    printf "%s\n" "$$" > "$1/infrastructure-guarded-child"
    while :; do sleep 0.1; done
  ' bash "$TMP"
) &
infra_signal_guard=$!
for _ in $(seq 1 100); do
  [ -s "$TMP/infrastructure-guarded-child" ] && break
  sleep 0.01
done
[ -s "$TMP/infrastructure-guarded-child" ] \
  || fail "signal-safe infrastructure guardian did not start its child"
infra_guarded_child="$(cat "$TMP/infrastructure-guarded-child")"
kill -TERM "$infra_signal_guard"
set +e
wait "$infra_signal_guard"
infra_signal_rc=$?
set -e
infra_signal_guard=""
[ "$infra_signal_rc" -eq 143 ] \
  || fail "infrastructure guardian did not preserve TERM status (got $infra_signal_rc)"
! kill -0 "$infra_guarded_child" 2>/dev/null \
  || fail "infrastructure guardian left its mutating child alive after TERM"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-signal-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run nowait true
) || fail "infrastructure guardian released the lock before reaping its child"
pass "infrastructure guardian forwards termination and reaps before unlock"

(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-quit-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_exec wait bash -c '
    trap "exit 131" QUIT
    printf "%s\n" "$$" > "$1/infrastructure-quit-child"
    while :; do sleep 0.1; done
  ' bash "$TMP"
) &
infra_signal_guard=$!
for _ in $(seq 1 100); do
  [ -s "$TMP/infrastructure-quit-child" ] && break
  sleep 0.01
done
[ -s "$TMP/infrastructure-quit-child" ] \
  || fail "SIGQUIT infrastructure guardian fixture did not start"
infra_quit_child="$(cat "$TMP/infrastructure-quit-child")"
kill -QUIT "$infra_signal_guard"
set +e
wait "$infra_signal_guard"
infra_quit_rc=$?
set -e
infra_signal_guard=""
[ "$infra_quit_rc" -eq 131 ] \
  || fail "infrastructure guardian did not preserve SIGQUIT status"
! kill -0 "$infra_quit_child" 2>/dev/null \
  || fail "infrastructure guardian left its child alive after SIGQUIT"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-quit-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run nowait true
) || fail "infrastructure guardian unlocked before reaping its SIGQUIT child"
pass "infrastructure guardian forwards SIGQUIT and reaps before unlock"

mkfifo "$TMP/infrastructure-group-release"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-group-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_exec wait bash -c '
    (
      trap ": > \"$1/infrastructure-group-cleanup\"; exec 8<> \"$1/infrastructure-group-release\"; IFS= read -r _ <&8; exit 0" TERM INT HUP
      while :; do sleep 0.1; done
    ) &
    printf "%s\n" "$!" > "$1/infrastructure-group-member"
    trap "exit 143" TERM INT HUP
    : > "$1/infrastructure-group-ready"
    while :; do sleep 0.1; done
  ' bash "$TMP"
) &
infra_signal_guard=$!
for _ in $(seq 1 100); do
  [ -e "$TMP/infrastructure-group-ready" ] && break
  sleep 0.01
done
[ -e "$TMP/infrastructure-group-ready" ] \
  || fail "infrastructure process-group fixture did not start"
kill -TERM "$infra_signal_guard"
for _ in $(seq 1 200); do
  [ -e "$TMP/infrastructure-group-cleanup" ] && break
  sleep 0.01
done
[ -e "$TMP/infrastructure-group-cleanup" ] \
  || fail "background group member did not enter TERM cleanup"
set +e
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-group-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run nowait true
) >/dev/null 2>&1
infra_group_contender_rc=$?
set -e
[ "$infra_group_contender_rc" -eq "$CKA_INFRA_LOCK_TIMEOUT_RC" ] \
  || fail "guardian unlocked while a signalled process-group member was live"
printf 'release\n' > "$TMP/infrastructure-group-release"
set +e
wait "$infra_signal_guard"
infra_group_signal_rc=$?
set -e
infra_signal_guard=""
[ "$infra_group_signal_rc" -eq 143 ] \
  || fail "process-group guardian did not preserve TERM status"
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-group-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run nowait true
) || fail "process-group guardian did not release after live members exited"

set +e
(
  CKA_INFRA_LOCK_ROOT="$TMP/infrastructure-status-gate"
  CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE=1
  infrastructure_lock_run wait bash -c 'exit 42'
) >/dev/null 2>&1
infra_status_rc=$?
set -e
[ "$infra_status_rc" -eq 42 ] \
  || fail "infrastructure guardian changed child status 42 to $infra_status_rc"
pass "infrastructure guardian holds through process-group cleanup and preserves status"

set +e
(
  CKA_STATE_DIR="$TMP/signal-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  mkdir -p "$EXAM_DIR/logs"
  : > "$EXAM_DIR/setup-attempted"
  set_exam_state PREPARING
  acquire_exam_lock start
  kill -TERM "${BASHPID:-$$}"
  printf 'continued\n' > "$CKA_STATE_DIR/continued"
) >/dev/null 2>&1
signal_rc=$?
set -e
[ "$signal_rc" -eq 143 ] || fail "TERM handler did not exit 143 (got $signal_rc)"
[ ! -e "$TMP/signal-state/continued" ] || fail "execution continued after TERM"
[ "$(tr -d '\r\n' < "$TMP/signal-state/exam/state")" = INVALID ] \
  || fail "interrupted PREPARING state is not INVALID"
[ ! -d "$TMP/signal-state/exam.lock" ] || fail "EXIT cleanup left the exam lock behind"
pass "signal handling exits nonzero, records INVALID, and releases only its lock"

set +e
(
  CKA_STATE_DIR="$TMP/cluster-fail-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  require_cluster() {
    exam_state > "$CKA_STATE_DIR/state-seen-by-require-cluster"
    return 7
  }
  cmd_start --seed cluster-failure-test
) >/dev/null 2>&1
cluster_fail_rc=$?
set -e
[ "$cluster_fail_rc" -ne 0 ] || fail "cluster preparation failure was accepted"
[ "$(cat "$TMP/cluster-fail-state/state-seen-by-require-cluster")" = PREPARING ] \
  || fail "PREPARING was not visible before require_cluster"
[ "$(cat "$TMP/cluster-fail-state/exam/state")" = INVALID ] \
  || fail "require_cluster failure did not become INVALID"
[ ! -d "$TMP/cluster-fail-state/exam.lock" ] || fail "cluster failure left a lock"
pass "start locks PREPARING before cluster checks and maps failure to INVALID"

set +e
(
  CKA_STATE_DIR="$TMP/baseline-fail-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  require_cluster() { return 0; }
  cluster_matches_version_lock() { return 0; }
  verify_cluster_cleanup_invariants() { return 1; }
  cmd_start --seed baseline-failure-test
) >/dev/null 2>&1
baseline_fail_rc=$?
set -e
[ "$baseline_fail_rc" -ne 0 ] || fail "broken cluster baseline was accepted"
[ "$(cat "$TMP/baseline-fail-state/exam/state")" = INVALID ] \
  || fail "broken cluster baseline did not become INVALID"
[ ! -e "$TMP/baseline-fail-state/exam/deadline" ] \
  || fail "broken cluster baseline created a deadline"
pass "broken node/scheduler/addon baseline prevents exam start"

(
  CKA_STATE_DIR="$TMP/cancel-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  require_cluster() {
    local i
    for i in $(seq 1 200); do
      [ -d "$EXAM_DIR/cancel-request" ] && return 0
      sleep 0.02
    done
    return 9
  }
  cluster_matches_version_lock() { return 0; }
  cmd_start --seed cancel-request-test
) >/dev/null 2>&1 &
starter_pid=$!
for _ in $(seq 1 200); do
  [ -r "$TMP/cancel-state/exam/state" ] \
    && [ "$(cat "$TMP/cancel-state/exam/state")" = PREPARING ] \
    && [ -r "$TMP/cancel-state/exam.lock/owner" ] \
    && break
  sleep 0.02
done
[ -r "$TMP/cancel-state/exam.lock/owner" ] || fail "background start did not acquire preparation lock"
(
  CKA_STATE_DIR="$TMP/cancel-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  cmd_abort
) >/dev/null
set +e
wait "$starter_pid"
cancel_start_rc=$?
set -e
[ "$cancel_start_rc" -ne 0 ] || fail "cancelled preparation reported a successful start"
[ "$(cat "$TMP/cancel-state/exam/state")" = INVALID ] \
  || fail "cancelled preparation did not end INVALID"
[ ! -d "$TMP/cancel-state/exam.lock" ] || fail "cancelled preparation left a lock"
pass "abort requests cancellation without stealing or signalling the preparation lock owner"

set +e
(
  EXAM_DIR="$TMP/state-write-fail/exam"
  mkdir -p "$EXAM_DIR"
  mv() { return 1; }
  set_exam_state RUNNING
  printf 'continued\n' > "$TMP/state-write-fail/continued"
) >/dev/null 2>&1
state_write_rc=$?
set -e
[ "$state_write_rc" -ne 0 ] || fail "state write failure returned success"
[ ! -e "$TMP/state-write-fail/continued" ] || fail "execution continued after state write failure"
pass "state write failures stop execution immediately"

set +e
(
  CKA_STATE_DIR="$TMP/setup-timeout-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  PLANNER="$TMP/setup-timeout-planner.sh"
  fake_qdir="$TMP/setup-timeout-question"
  mkdir -p "$fake_qdir"
  cat > "$PLANNER" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --questions-out) questions="$2"; shift 2 ;;
    --setup-order-out) setup="$2"; shift 2 ;;
    --validate) exit 0 ;;
    *) shift ;;
  esac
done
printf 'st-99\n' > "$questions"
printf 'st-99\n' > "$setup"
EOF
  cat > "$fake_qdir/meta.yaml" <<'EOF'
id: st-99
title: timeout fixture
domain: storage
points: 1
EOF
  cat > "$fake_qdir/setup.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_qdir/grade.sh"
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  require_cluster() { return 0; }
  cluster_matches_version_lock() { return 0; }
  cleanup_question() { return 0; }
  SETUP_TIMEOUT_SEC=1
  CLEANUP_TIMEOUT_SEC=1
  cmd_start --seed setup-timeout-test
) >/dev/null 2>&1
setup_timeout_rc=$?
set -e
[ "$setup_timeout_rc" -ne 0 ] || fail "setup timeout was accepted"
[ "$(cat "$TMP/setup-timeout-state/exam/state")" = INVALID ] \
  || fail "setup timeout did not produce INVALID"
grep -q 'setup timeout' "$TMP/setup-timeout-state/exam/failure" \
  || fail "setup timeout reason was not recorded"
pass "question setup timeout produces INVALID"

set +e
(
  CKA_STATE_DIR="$TMP/preflight-timeout-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  PLANNER="$TMP/preflight-timeout-planner.sh"
  fake_qdir="$TMP/preflight-timeout-question"
  mkdir -p "$fake_qdir"
  cat > "$PLANNER" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --questions-out) questions="$2"; shift 2 ;;
    --setup-order-out) setup="$2"; shift 2 ;;
    --validate) exit 0 ;;
    *) shift ;;
  esac
done
printf 'st-98\n' > "$questions"
printf 'st-98\n' > "$setup"
EOF
  cat > "$fake_qdir/meta.yaml" <<'EOF'
id: st-98
title: preflight timeout fixture
domain: storage
points: 1
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_qdir/setup.sh"
  cat > "$fake_qdir/grade.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
EOF
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  require_cluster() { return 0; }
  cluster_matches_version_lock() { return 0; }
  cleanup_question() { return 0; }
  GRADE_TIMEOUT_SEC=1
  CLEANUP_TIMEOUT_SEC=1
  cmd_start --seed preflight-timeout-test
) >/dev/null 2>&1
preflight_timeout_rc=$?
set -e
[ "$preflight_timeout_rc" -ne 0 ] || fail "preflight timeout was accepted"
[ "$(cat "$TMP/preflight-timeout-state/exam/state")" = INVALID ] \
  || fail "preflight timeout did not produce INVALID"
grep -q '끝나지 않았습니다' "$TMP/preflight-timeout-state/exam/failure" \
  || fail "preflight timeout reason was not recorded"
pass "preflight grader timeout produces INVALID"

(
  CKA_STATE_DIR="$TMP/final-timeout-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  PLANNER="$TMP/final-timeout-planner.sh"
  fake_qdir="$TMP/final-timeout-question"
  mkdir -p "$fake_qdir"
  cat > "$PLANNER" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --questions-out) questions="$2"; shift 2 ;;
    --setup-order-out) setup="$2"; shift 2 ;;
    --validate) exit 0 ;;
    *) shift ;;
  esac
done
printf 'st-97\n' > "$questions"
printf 'st-97\n' > "$setup"
EOF
  cat > "$fake_qdir/meta.yaml" <<'EOF'
id: st-97
title: final grade timeout fixture
domain: storage
points: 1
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_qdir/setup.sh"
  cat > "$fake_qdir/grade.sh" <<EOF
#!/usr/bin/env bash
if [ ! -e "$TMP/final-timeout-grade-once" ]; then
  mkdir -p "$CKA_STATE_DIR/status"
  printf 'graded:0/1' > "$CKA_STATE_DIR/status/st-97"
  : > "$TMP/final-timeout-grade-once"
  exit 1
fi
sleep 2
EOF
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  require_cluster() { return 0; }
  cluster_matches_version_lock() { return 0; }
  cleanup_question() { return 0; }
  GRADE_TIMEOUT_SEC=1
  CLEANUP_TIMEOUT_SEC=1
  cmd_start --seed final-timeout-test >/dev/null
  cmd_finish >/dev/null
  [ "$(exam_state)" = INVALID ] || fail "final grader timeout terminal state is not INVALID"
  result_file="$(cat "$EXAM_DIR/result")"
  grep -q '^result: INVALID$' "$result_file" || fail "final grader timeout result was not preserved as INVALID"
)
pass "final grader timeout preserves results and produces INVALID"

(
  CKA_STATE_DIR="$TMP/final-partial-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  fake_qdir="$TMP/final-partial-question"
  mkdir -p "$EXAM_DIR/logs" "$fake_qdir"
  cat > "$fake_qdir/meta.yaml" <<'EOF'
id: st-94
title: valid partial grade fixture
domain: storage
points: 1
EOF
  cat > "$fake_qdir/grade.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$CKA_STATE_DIR/status"
printf 'graded:0/1' > "$CKA_STATE_DIR/status/st-94"
exit 1
EOF
  printf 'st-94\n' > "$EXAM_DIR/questions"
  printf 'st-94\n' > "$EXAM_DIR/setup-attempted"
  printf 'final-partial-test\n' > "$EXAM_DIR/seed"
  printf 'final-partial-run\n' > "$EXAM_DIR/run-id"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$EXAM_DIR/deadline"
  set_exam_state RUNNING
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  cleanup_question() { return 0; }
  cmd_finish >/dev/null
  [ "$(exam_state)" = ARCHIVED ] || fail "valid partial grade did not archive normally"
  result_file="$(cat "$EXAM_DIR/result")"
  grep -q '^result: FAIL$' "$result_file" || fail "valid partial grade did not produce FAIL"
)
pass "grader exit 1 remains a valid partial result in final grading"

(
  CKA_STATE_DIR="$TMP/abort-cleanup-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  fake_qdir="$TMP/abort-cleanup-question"
  mkdir -p "$EXAM_DIR/logs" "$fake_qdir"
  printf 'st-96\n' > "$EXAM_DIR/questions"
  printf 'st-96\n' > "$EXAM_DIR/setup-attempted"
  printf 'abort-cleanup-test\n' > "$EXAM_DIR/seed"
  set_exam_state RUNNING
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  cleanup_question() { return 1; }
  CLEANUP_TIMEOUT_SEC=1
  abort_rc=0
  cmd_abort >/dev/null 2>&1 || abort_rc=$?
  [ "$abort_rc" -ne 0 ] || fail "abort cleanup failure returned success"
  [ "$(exam_state)" = INVALID ] || fail "abort cleanup failure terminal state is not INVALID"
  result_file="$(cat "$EXAM_DIR/result")"
  grep -q '^result: INVALID$' "$result_file" || fail "abort cleanup failure did not preserve INVALID result"
)
pass "abort cleanup failure is aggregated and ends INVALID"

set +e
(
  CKA_STATE_DIR="$TMP/finish-cleanup-state"
  EXAM_DIR="$CKA_STATE_DIR/exam"
  RESULT_DIR="$CKA_STATE_DIR/exam-results"
  LOCK_DIR="$CKA_STATE_DIR/exam.lock"
  fake_qdir="$TMP/finish-cleanup-question"
  mkdir -p "$EXAM_DIR/logs" "$fake_qdir"
  cat > "$fake_qdir/meta.yaml" <<'EOF'
id: st-95
title: finish cleanup fixture
domain: storage
points: 1
EOF
  cat > "$fake_qdir/grade.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$CKA_STATE_DIR/status"
printf 'graded:1/1' > "$CKA_STATE_DIR/status/st-95"
EOF
  printf 'st-95\n' > "$EXAM_DIR/questions"
  printf 'st-95\n' > "$EXAM_DIR/setup-attempted"
  printf 'finish-cleanup-test\n' > "$EXAM_DIR/seed"
  printf 'finish-cleanup-run\n' > "$EXAM_DIR/run-id"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$EXAM_DIR/deadline"
  set_exam_state RUNNING
  qdir_of() { printf '%s\n' "$fake_qdir"; }
  cleanup_question() { return 1; }
  CLEANUP_TIMEOUT_SEC=1
  cmd_finish >/dev/null
  [ "$(exam_state)" = INVALID ] || fail "finish cleanup failure terminal state is not INVALID"
  result_file="$(cat "$EXAM_DIR/result")"
  grep -q '^result: INVALID$' "$result_file" || fail "finish cleanup failure result is not INVALID"
  grep -q '^cleanup_failed: 1$' "$result_file" || fail "finish cleanup failure flag was not preserved"
)
finish_cleanup_rc=$?
set -e
[ "$finish_cleanup_rc" -eq 0 ] || fail "finish cleanup regression block exited $finish_cleanup_rc"
pass "finish cleanup failure preserves scorecard and ends INVALID"

if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
    "$ROOT/exam/question.schema.json"
  pass "question schema is valid JSON"
fi

printf 'all exam runner tests passed\n'
