#!/usr/bin/env bash
# Mock exam runner: compatible form, strict preflight, hard deadline, scorecard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

EXAM_DIR="$CKA_STATE_DIR/exam"
RESULT_DIR="$CKA_STATE_DIR/exam-results"
LOCK_DIR="$CKA_STATE_DIR/exam.lock"
PLANNER="$SCRIPT_DIR/planner.sh"
DURATION_MIN=120
PASS_PCT=66
SETUP_TIMEOUT_SEC=180
GRADE_TIMEOUT_SEC=60
CLEANUP_TIMEOUT_SEC=120
CLEANUP_TOTAL_TIMEOUT_SEC=600
EXAM_LOCK_HELD=0
EXAM_LOCK_TOKEN=""
EXAM_LOCK_ACTION=""

for timeout_value in "$SETUP_TIMEOUT_SEC" "$GRADE_TIMEOUT_SEC" "$CLEANUP_TIMEOUT_SEC" "$CLEANUP_TOTAL_TIMEOUT_SEC"; do
  [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]] || die "내부 오류: 작업 timeout은 양의 정수여야 합니다."
done

# Public state interface for cka/web and other front ends:
#   $CKA_STATE_DIR/exam/state = PREPARING|RUNNING|SEALED|GRADING|ARCHIVED|INVALID
exam_state() {
  if [ -r "$EXAM_DIR/state" ]; then
    tr -d '\r\n' < "$EXAM_DIR/state"
  else
    printf 'NONE'
  fi
}

state_is_active() {
  case "${1:-$(exam_state)}" in
    PREPARING|RUNNING|SEALED|GRADING) return 0 ;;
    *) return 1 ;;
  esac
}

exam_running() { state_is_active; }

set_exam_state() {
  local next="$1" tmp
  case "$next" in
    PREPARING|RUNNING|SEALED|GRADING|ARCHIVED|INVALID) ;;
    *) die "내부 오류: 알 수 없는 시험 상태 $next" ;;
  esac
  mkdir -p "$EXAM_DIR" || die "시험 상태 디렉터리를 만들 수 없습니다: $EXAM_DIR"
  tmp="$EXAM_DIR/.state.$$"
  printf '%s\n' "$next" > "$tmp" \
    || die "시험 상태 임시 파일을 쓸 수 없습니다: $tmp"
  if ! mv -f "$tmp" "$EXAM_DIR/state"; then
    rm -f -- "$tmp" 2>/dev/null || true
    die "시험 상태를 원자적으로 저장할 수 없습니다: $EXAM_DIR/state"
  fi
}

transition_state() {
  local next="$1" current
  current="$(exam_state)"
  case "$current:$next" in
    NONE:PREPARING|ARCHIVED:PREPARING|INVALID:PREPARING|\
    PREPARING:RUNNING|PREPARING:SEALED|PREPARING:INVALID|\
    RUNNING:SEALED|SEALED:GRADING|SEALED:ARCHIVED|SEALED:INVALID|\
    GRADING:ARCHIVED|GRADING:INVALID) ;;
    *) die "내부 오류: 허용되지 않은 시험 상태 전이 $current → $next" ;;
  esac
  set_exam_state "$next"
}

safe_reset_exam_dir() {
  [ -n "$EXAM_DIR" ] && [ "$EXAM_DIR" = "$CKA_STATE_DIR/exam" ] \
    || die "내부 오류: 안전하지 않은 시험 상태 경로"
  state_subdir_clear exam \
    || die "시험 상태 디렉터리를 안전하게 초기화할 수 없습니다."
  mkdir -p "$EXAM_DIR/logs"
}

acquire_exam_lock() {
  local action="${1:-command}" owner_pid="${BASHPID:-$$}"
  local owner="" token="" extra="" owner_tmp="" gate_tmp="" gate_token=""
  local gate_owner="" gate_seen_token="" gate_extra="" attempt gate_acquired=0
  mkdir -p "$CKA_STATE_DIR" "$LOCK_DIR" \
    || die "시험 lock 디렉터리를 준비할 수 없습니다."
  EXAM_LOCK_TOKEN="$owner_pid-${RANDOM:-0}-${RANDOM:-0}"
  gate_token="$owner_pid-gate-${RANDOM:-0}-${RANDOM:-0}"

  # Fully-written records are published with atomic hard links. A short-lived
  # acquisition gate serializes stale-owner validation, unlink, and new-owner
  # publication so two reclaimers cannot both win through an ABA race.
  owner_tmp="$CKA_STATE_DIR/.exam-lock-owner.$owner_pid.${RANDOM:-0}"
  gate_tmp="$CKA_STATE_DIR/.exam-lock-gate.$owner_pid.${RANDOM:-0}"
  ( umask 077; printf '%s %s\n' "$owner_pid" "$EXAM_LOCK_TOKEN" > "$owner_tmp" ) \
    || die "시험 lock 소유자 임시 파일을 쓸 수 없습니다."
  ( umask 077; printf '%s %s\n' "$owner_pid" "$gate_token" > "$gate_tmp" ) \
    || { rm -f -- "$owner_tmp"; die "시험 lock gate 임시 파일을 쓸 수 없습니다."; }

  for attempt in $(seq 1 100); do
    if ln "$gate_tmp" "$LOCK_DIR/acquire-gate" 2>/dev/null; then
      gate_acquired=1
      break
    fi
    gate_owner=""; gate_seen_token=""; gate_extra=""
    if [ -r "$LOCK_DIR/acquire-gate" ]; then
      IFS=' ' read -r gate_owner gate_seen_token gate_extra \
        < "$LOCK_DIR/acquire-gate" || true
    fi
    if ! [[ "$gate_owner" =~ ^[0-9]+$ ]] || [ -z "$gate_seen_token" ] \
        || [ -n "$gate_extra" ] || ! kill -0 "$gate_owner" 2>/dev/null; then
      rm -f -- "$owner_tmp" "$gate_tmp"
      die "시험 lock acquisition gate가 손상되었거나 중단되었습니다. 수동 확인이 필요합니다."
    fi
    sleep 0.02
  done
  rm -f -- "$gate_tmp"
  gate_tmp=""
  if [ "$gate_acquired" -ne 1 ]; then
    rm -f -- "$owner_tmp"
    die "다른 시험 명령이 lock을 획득 중입니다. 잠시 후 다시 시도하세요."
  fi

  owner=""; token=""; extra=""
  if [ -r "$LOCK_DIR/owner" ]; then
    IFS=' ' read -r owner token extra < "$LOCK_DIR/owner" || true
    if ! [[ "$owner" =~ ^[0-9]+$ ]] || [ -z "$token" ] || [ -n "$extra" ]; then
      rm -f -- "$LOCK_DIR/acquire-gate" "$owner_tmp"
      die "시험 lock 소유자 정보가 손상되었습니다. 수동 확인이 필요합니다."
    fi
    if kill -0 "$owner" 2>/dev/null; then
      rm -f -- "$LOCK_DIR/acquire-gate" "$owner_tmp"
      die "다른 시험 명령이 실행 중입니다 (pid $owner)."
    fi
    rm -f -- "$LOCK_DIR/owner" \
      || { rm -f -- "$LOCK_DIR/acquire-gate" "$owner_tmp"; die "stale 시험 lock을 정리할 수 없습니다."; }
  fi

  if ! ln "$owner_tmp" "$LOCK_DIR/owner" 2>/dev/null; then
    rm -f -- "$LOCK_DIR/acquire-gate" "$owner_tmp"
    die "시험 lock 소유권을 게시할 수 없습니다."
  fi
  rm -f -- "$owner_tmp"
  if ! rm -f -- "$LOCK_DIR/acquire-gate"; then
    rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
    die "시험 lock acquisition gate를 해제할 수 없습니다."
  fi
  EXAM_LOCK_HELD=1
  EXAM_LOCK_ACTION="$action"
  trap release_exam_lock EXIT
  trap 'handle_exam_signal INT 130' INT
  trap 'handle_exam_signal TERM 143' TERM
}

release_exam_lock() {
  local owner="" token="" extra=""
  if [ -r "$LOCK_DIR/owner" ]; then
    IFS=' ' read -r owner token extra < "$LOCK_DIR/owner" || true
  fi
  if [ "$EXAM_LOCK_HELD" -eq 1 ] && [ -n "$EXAM_LOCK_TOKEN" ] \
      && [ "$token" = "$EXAM_LOCK_TOKEN" ] && [ -z "$extra" ] \
      && [ -d "$LOCK_DIR" ] && [ "$LOCK_DIR" = "$CKA_STATE_DIR/exam.lock" ]; then
    rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  EXAM_LOCK_HELD=0
  EXAM_LOCK_TOKEN=""
  EXAM_LOCK_ACTION=""
  trap - EXIT
}

unlock_exam_command() {
  trap - INT TERM
  release_exam_lock
}

exam_lock_is_ours() {
  local owner="" token="" extra=""
  [ "$EXAM_LOCK_HELD" -eq 1 ] || return 1
  [ -r "$LOCK_DIR/owner" ] || return 1
  IFS=' ' read -r owner token extra < "$LOCK_DIR/owner" || true
  [ -n "$EXAM_LOCK_TOKEN" ] && [ "$token" = "$EXAM_LOCK_TOKEN" ] \
    && [ -z "$extra" ]
}

handle_exam_signal() {
  local signal_name="$1" exit_code="$2" state reason
  trap - INT TERM
  state="$(exam_state)"
  reason="시험 명령이 ${signal_name} signal로 중단되었습니다."

  # Read-only commands must never change the candidate's exam state. For a
  # mutating command, leave a terminal/recoverable state before EXIT unlocks.
  case "$EXAM_LOCK_ACTION:$state" in
    status:*|question:*) ;;
    abort:PREPARING|start:PREPARING)
      printf '%s\n' "SIGNAL_$signal_name" > "$EXAM_DIR/failure"
      archive_invalid_run "$reason" || true
      cleanup_exam_environment || printf '%s\n' CLEANUP_FAILED >> "$EXAM_DIR/failure"
      set_exam_state INVALID
      ;;
    finish:GRADING)
      printf '%s\n' "SIGNAL_$signal_name" > "$EXAM_DIR/failure"
      archive_invalid_run "$reason" || true
      cleanup_exam_environment || printf '%s\n' CLEANUP_FAILED >> "$EXAM_DIR/failure"
      set_exam_state INVALID
      ;;
    abort:RUNNING)
      printf '%s\n' "SIGNAL_$signal_name" > "$EXAM_DIR/seal-reason"
      if cleanup_exam_environment; then
        set_exam_state ARCHIVED
      else
        archive_invalid_run "$reason (cleanup 실패)" || true
        set_exam_state INVALID
      fi
      ;;
    abort:SEALED)
      if cleanup_exam_environment; then
        set_exam_state ARCHIVED
      else
        archive_invalid_run "$reason (cleanup 실패)" || true
        set_exam_state INVALID
      fi
      ;;
    start:RUNNING|finish:RUNNING)
      seal_exam "SIGNAL_$signal_name" || true
      ;;
    *) ;;
  esac
  err "$reason"
  exit "$exit_code"
}

exam_now() {
  # Never accept a candidate-controlled clock. Cluster-free tests replace this
  # shell function after sourcing the runner instead of exposing a production
  # environment-variable override.
  date +%s
}

qid_of_num() { # q7 or 7 -> question id
  local n="${1#q}"
  sed -n "${n}p" "$EXAM_DIR/questions" 2>/dev/null
}

remaining_seconds() {
  local deadline now
  deadline="$(cat "$EXAM_DIR/deadline" 2>/dev/null || true)"
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  now="$(exam_now)"
  printf '%s\n' "$((deadline - now))"
}

fmt_mmss() {
  local s=$1
  [ "$s" -lt 0 ] && { printf -- '-'; s=$((-s)); }
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

seal_exam() {
  local reason="$1"
  exam_lock_is_ours || die "내부 오류: 시험 lock 없이 답안을 봉인할 수 없습니다."
  [ "$(exam_state)" = RUNNING ] || return 0
  printf '%s\n' "$reason" > "$EXAM_DIR/seal-reason" \
    || die "답안 봉인 사유를 기록할 수 없습니다."
  exam_now > "$EXAM_DIR/sealed-at" \
    || die "답안 봉인 시각을 기록할 수 없습니다."
  transition_state SEALED
}

sync_deadline_state() {
  exam_lock_is_ours || die "내부 오류: 시험 lock 없이 deadline 상태를 변경할 수 없습니다."
  [ "$(exam_state)" = RUNNING ] || return 0
  local rem
  if ! rem="$(remaining_seconds)"; then
    printf '%s\n' "MISSING_DEADLINE" > "$EXAM_DIR/failure" \
      || die "deadline 오류를 기록할 수 없습니다."
    seal_exam STATE_ERROR || true
    return 1
  fi
  if [ "$rem" -le 0 ]; then
    seal_exam TIMEOUT
  fi
}

score_is_pass() { # score_is_pass <pct> <timed-out:0|1> <invalid:0|1>
  [ "$2" -eq 0 ] && [ "$3" -eq 0 ] && [ "$1" -ge "$PASS_PCT" ]
}

parse_grade_state() {
  local value="$1"
  PARSED_EARNED=""
  PARSED_MAX=""
  if [[ "$value" =~ ^graded:([0-9]+)/([0-9]+)$ ]]; then
    PARSED_EARNED="${BASH_REMATCH[1]}"
    PARSED_MAX="${BASH_REMATCH[2]}"
    [ "$PARSED_MAX" -gt 0 ] && [ "$PARSED_EARNED" -le "$PARSED_MAX" ]
  else
    return 1
  fi
}

run_bounded() { # run_bounded <seconds> <command> [args...]
  local seconds="$1"
  shift
  command timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
}

verify_question_cleanup() {
  local id="$1" remaining=""
  remaining="$(kctx --request-timeout=15s get \
    namespaces,persistentvolumes,storageclasses,priorityclasses,clusterroles,clusterrolebindings,gatewayclasses \
    -l "$CKA_LABEL_KEY=$id" -o name 2>/dev/null)" || return 1
  [ -z "$remaining" ] && [ ! -d "$CKA_WORK_DIR/$id" ]
}

verify_cluster_cleanup_invariants() {
  local deadline="${1:-$(( $(date +%s) + CLEANUP_TOTAL_TIMEOUT_SEC ))}"
  local node ready unschedulable taint_effects remaining step_timeout entry ns deploy
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || return 1
  cluster_matches_version_lock || return 1
  step_timeout="$remaining"; [ "$step_timeout" -le 90 ] || step_timeout=90
  kctx wait --for=condition=Ready nodes --all --timeout="${step_timeout}s" >/dev/null 2>&1 \
    || return 1
  for node in "${CKA_CLUSTER_NAME}-worker" "${CKA_CLUSTER_NAME}-worker2"; do
    ready="$(kctx --request-timeout=15s get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" \
      || return 1
    unschedulable="$(kctx --request-timeout=15s get node "$node" \
      -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" || return 1
    [ "$ready" = True ] && [ "$unschedulable" != true ] || return 1
    taint_effects="$(kctx --request-timeout=15s get node "$node" \
      -o jsonpath='{range .spec.taints[*]}{.effect}{"\n"}{end}' 2>/dev/null)" \
      || return 1
    ! printf '%s\n' "$taint_effects" | grep -Eq '^(NoSchedule|NoExecute)$' \
      || return 1
  done
  docker exec "${CKA_CLUSTER_NAME}-worker" test ! -e /etc/kubernetes/manifests/static-web.yaml \
    >/dev/null 2>&1 || return 1
  [ "$(kctx --request-timeout=15s -n kube-system get \
      pod "kube-scheduler-${CKA_CLUSTER_NAME}-control-plane" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || return 1
  for entry in \
      kube-system:coredns \
      kube-system:metrics-server \
      ingress-nginx:ingress-nginx-controller \
      cka-system:grader-client; do
    ns="${entry%%:*}"; deploy="${entry#*:}"
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 1
    step_timeout="$remaining"; [ "$step_timeout" -le 90 ] || step_timeout=90
    kctx -n "$ns" rollout status "deploy/$deploy" --timeout="${step_timeout}s" \
      >/dev/null 2>&1 || return 1
  done
}

verify_cluster_cleanup_invariants_bounded() { # <absolute-deadline-epoch>
  local deadline="$1" remaining
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || return 1
  # Run the complete invariant probe under the same total cleanup deadline.
  # Individual kubectl/docker calls can otherwise outlive the web controller's
  # termination grace and leave GRADING/PREPARING plus the lock behind.
  run_bounded "$remaining" env CKA_EXAM_SOURCE_ONLY=0 \
    bash "$SCRIPT_DIR/mock-exam.sh" \
    __verify-cleanup-invariants "$deadline"
}

cleanup_question_bounded() { # cleanup_question_bounded <seconds> <id>
  local seconds="$1" id="$2" common="$SCRIPT_DIR/../lib/common.sh"
  run_bounded "$seconds" bash -c \
    'set -uo pipefail; source "$1"; cleanup_question "$2"' \
    cka-cleanup "$common" "$id"
}

node_has_only_managed_pods() { # node_has_only_managed_pods <node>
  kctx --request-timeout=20s get pods -A --field-selector "spec.nodeName=$1" -o json \
    2>/dev/null | python3 -c '
import json, sys

items = json.load(sys.stdin).get("items", [])
unmanaged = []
for pod in items:
    meta = pod.get("metadata", {})
    if meta.get("annotations", {}).get("kubernetes.io/config.mirror"):
        continue
    refs = meta.get("ownerReferences", [])
    if any(ref.get("controller") is True for ref in refs):
        continue
    namespace = meta.get("namespace") or "default"
    name = meta.get("name") or "unknown"
    unmanaged.append(namespace + "/" + name)
if unmanaged:
    print("unmanaged Pods: " + ", ".join(unmanaged), file=sys.stderr)
    raise SystemExit(1)
'
}

verify_form_runtime_requirements() { # verify_form_runtime_requirements <questions-file>
  local questions="$1"
  if grep -qx ca-05 "$questions"; then
    node_has_only_managed_pods "${CKA_CLUSTER_NAME}-worker" || return 1
  fi
  if grep -qx ca-06 "$questions"; then
    node_has_only_managed_pods "${CKA_CLUSTER_NAME}-worker2" || return 1
  fi
}

cleanup_exam_environment() {
  local order="$EXAM_DIR/setup-attempted" id qdir failed=0 index
  local cleanup_log="$EXAM_DIR/logs/cleanup.log"
  local cleanup_deadline=$(( $(date +%s) + CLEANUP_TOTAL_TIMEOUT_SEC ))
  local remaining step_timeout
  local -a cleanup_ids=()
  mkdir -p "$EXAM_DIR/logs" || return 1
  : > "$cleanup_log" || return 1
  [ -r "$order" ] || order="$EXAM_DIR/setup-order"
  [ -r "$order" ] || order="$EXAM_DIR/questions"
  [ -r "$order" ] || return "$failed"
  mapfile -t cleanup_ids < "$order" || return 1
  for ((index=${#cleanup_ids[@]} - 1; index >= 0; index--)); do
    id="${cleanup_ids[$index]}"
    [ -n "$id" ] || continue
    qdir="$(qdir_of "$id" 2>/dev/null || true)"
    if [ -z "$qdir" ]; then
      printf 'question directory missing: %s\n' "$id" >> "$cleanup_log"
      failed=1
      continue
    fi
    remaining=$((cleanup_deadline - $(date +%s)))
    if [ "$remaining" -le 0 ]; then
      printf 'cleanup total timeout before: %s\n' "$id" >> "$cleanup_log"
      failed=1
      break
    fi
    step_timeout="$remaining"
    [ "$step_timeout" -le "$CLEANUP_TIMEOUT_SEC" ] || step_timeout="$CLEANUP_TIMEOUT_SEC"
    if [ -f "$qdir/teardown.sh" ]; then
      if ! run_bounded "$step_timeout" bash "$qdir/teardown.sh" >> "$cleanup_log" 2>&1; then
        printf 'teardown failed: %s\n' "$id" >> "$cleanup_log"
        failed=1
      fi
    fi
    remaining=$((cleanup_deadline - $(date +%s)))
    if [ "$remaining" -le 0 ]; then
      printf 'cleanup total timeout after teardown: %s\n' "$id" >> "$cleanup_log"
      failed=1
      break
    fi
    step_timeout="$remaining"
    [ "$step_timeout" -le "$CLEANUP_TIMEOUT_SEC" ] || step_timeout="$CLEANUP_TIMEOUT_SEC"
    if ! cleanup_question_bounded "$step_timeout" "$id" >> "$cleanup_log" 2>&1; then
      printf 'cleanup_question failed: %s\n' "$id" >> "$cleanup_log"
      failed=1
    fi
    if ! verify_question_cleanup "$id" >> "$cleanup_log" 2>&1; then
      printf 'cleanup verification failed: %s\n' "$id" >> "$cleanup_log"
      failed=1
    fi
    if ! state_clear "$id" >> "$cleanup_log" 2>&1; then
      printf 'state_clear failed: %s\n' "$id" >> "$cleanup_log"
      failed=1
    fi
  done
  if ! verify_cluster_cleanup_invariants_bounded "$cleanup_deadline" \
      >> "$cleanup_log" 2>&1; then
    printf 'cluster cleanup invariants failed\n' >> "$cleanup_log"
    failed=1
  fi
  return "$failed"
}

archive_submissions() {
  local destination="$1" id source failed=0
  [ -r "$EXAM_DIR/questions" ] || return 0
  while IFS= read -r id; do
    source="$CKA_WORK_DIR/$id"
    [ -d "$source" ] || continue
    mkdir -p "$destination/$id" || { failed=1; continue; }
    cp -a "$source/." "$destination/$id/" 2>/dev/null \
      || { warn "$id 제출 파일 보관 실패"; failed=1; }
  done < "$EXAM_DIR/questions"
  return "$failed"
}

archive_invalid_run() {
  local reason="$1" result
  mkdir -p "$RESULT_DIR" || die "INVALID 결과 디렉터리를 만들 수 없습니다: $RESULT_DIR"
  result="$RESULT_DIR/$(date +%Y%m%d-%H%M%S)-invalid-$$.txt"
  {
    printf 'date: %s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'result: INVALID\n'
    printf 'phase: %s\n' "$(exam_state)"
    printf 'seed: %s\n' "$(cat "$EXAM_DIR/seed" 2>/dev/null || printf unknown)"
    printf 'reason: %s\n' "$reason"
  } > "$result" || die "INVALID 결과 파일을 쓸 수 없습니다: $result"
  printf '%s\n' "$result" > "$EXAM_DIR/result" \
    || die "INVALID 결과 경로를 기록할 수 없습니다."
}

fail_preparation() {
  local reason="$1" cleanup_failed=0 result_path=""
  printf '%s\n' "$reason" > "$EXAM_DIR/failure" \
    || die "준비 실패 사유를 기록할 수 없습니다."
  archive_invalid_run "$reason"
  result_path="$(cat "$EXAM_DIR/result" 2>/dev/null || true)"
  if ! cleanup_exam_environment; then
    cleanup_failed=1
    printf '%s\n' "CLEANUP_FAILED" >> "$EXAM_DIR/failure"
    [ -n "$result_path" ] && printf 'cleanup_failed: 1\n' >> "$result_path" 2>/dev/null || true
  fi
  transition_state INVALID
  err "$reason"
  [ "$cleanup_failed" -eq 0 ] || err "환경 정리가 완전하지 않아 cleanup 로그를 확인해야 합니다."
  err "시험을 시작하지 않았습니다. 로그: $EXAM_DIR/logs"
  return 1
}

preparation_cancel_requested() {
  [ -d "$EXAM_DIR/cancel-request" ]
}

request_preparation_cancel() {
  local owner="" token="" extra=""
  [ "$(exam_state)" = PREPARING ] || return 1
  [ ! -d "$EXAM_DIR/start-commit" ] || return 2
  [ -r "$LOCK_DIR/owner" ] || return 1
  IFS=' ' read -r owner token extra < "$LOCK_DIR/owner" || true
  # A cancellation is a filesystem request to the current owner. Never send a
  # signal to a PID read from mutable state; PID reuse could target another job.
  if ! [[ "$owner" =~ ^[0-9]+$ ]] || [ -z "$token" ] || [ -n "$extra" ] \
      || ! kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  mkdir "$EXAM_DIR/cancel-request" 2>/dev/null \
    || [ -d "$EXAM_DIR/cancel-request" ] \
    || return 1
  # If commit began concurrently, do not claim the request was accepted. The
  # caller waits for RUNNING and then executes the normal locked abort path.
  [ ! -d "$EXAM_DIR/start-commit" ] || return 2
  [ "$(exam_state)" = PREPARING ] || return 2
  return 0
}

preflight_form() {
  local id qdir grade_state expected_points grade_rc
  printf '\n%s\n' "${C_BLD}전체 문항 preflight를 검사합니다...${C_RST}"
  while IFS= read -r id; do
    if preparation_cancel_requested; then
      printf '%s\n' "사용자가 preflight 중 취소를 요청했습니다." > "$EXAM_DIR/preflight-error"
      return 1
    fi
    qdir="$(qdir_of "$id")" || return 1
    state_clear "$id"
    if run_bounded "$GRADE_TIMEOUT_SEC" bash "$qdir/grade.sh" \
        > "$EXAM_DIR/logs/$id-preflight.log" 2>&1; then
      grade_rc=0
    else
      grade_rc=$?
    fi
    if [ "$grade_rc" -eq 124 ] || [ "$grade_rc" -eq 137 ]; then
      printf '%s\n' "$id preflight grader가 ${GRADE_TIMEOUT_SEC}초 안에 끝나지 않았습니다." > "$EXAM_DIR/preflight-error"
      return 1
    fi
    # Graders intentionally return 1 for a valid, non-perfect candidate result.
    # Only exit codes other than PASS(0)/FAIL(1) are infrastructure failures.
    if [ "$grade_rc" -ne 0 ] && [ "$grade_rc" -ne 1 ]; then
      printf '%s\n' "$id preflight grader가 비정상 종료했습니다 (exit=$grade_rc)." > "$EXAM_DIR/preflight-error"
      return 1
    fi
    grade_state="$(state_get "$id")"
    if ! parse_grade_state "$grade_state"; then
      printf '%s\n' "$id grader가 유효한 점수를 기록하지 않았습니다: $grade_state" > "$EXAM_DIR/preflight-error"
      return 1
    fi
    expected_points="$(meta_get "$qdir" points)"
    if ! [[ "$expected_points" =~ ^[1-9][0-9]*$ ]] || [ "$PARSED_MAX" -ne "$expected_points" ]; then
      printf '%s\n' "$id 배점 불일치: meta=$expected_points grader=$PARSED_MAX" > "$EXAM_DIR/preflight-error"
      return 1
    fi
    if [ "$PARSED_EARNED" -eq "$PARSED_MAX" ]; then
      printf '%s\n' "$id setup 직후 이미 만점입니다 ($PARSED_EARNED/$PARSED_MAX)" > "$EXAM_DIR/preflight-error"
      return 1
    fi
    state_clear "$id"
  done < "$EXAM_DIR/questions"
  if preparation_cancel_requested; then
    printf '%s\n' "사용자가 preflight 완료 직후 취소를 요청했습니다." > "$EXAM_DIR/preflight-error"
    return 1
  fi
  return 0
}

cmd_start() {
  local seed="${CKA_EXAM_SEED:-}" id qdir i=0 started deadline
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --seed) [ "$#" -ge 2 ] || die "--seed 값이 필요합니다."; seed="$2"; shift 2 ;;
      *) die "사용법: cka exam [start] [--seed <seed>]" ;;
    esac
  done
  if [ -n "$seed" ] && ! [[ "$seed" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    die "seed에는 영문자, 숫자, '.', '_', ':', '-'만 사용할 수 있습니다."
  fi

  acquire_exam_lock start
  state_is_active "$(exam_state)" \
    && die "이미 진행 중인 모의고사가 있습니다. 'cka exam status' / 'cka exam finish' / 'cka exam abort'"

  safe_reset_exam_dir
  transition_state PREPARING
  : > "$EXAM_DIR/setup-attempted" \
    || die "setup 추적 파일을 만들 수 없습니다."
  [ -n "$seed" ] || seed="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  printf '%s\n' "$seed" > "$EXAM_DIR/seed" \
    || die "시험 seed를 기록할 수 없습니다."
  printf '%s\n' "$(date -u +%Y%m%dT%H%M%SZ)-$$" > "$EXAM_DIR/run-id" \
    || die "시험 run ID를 기록할 수 없습니다."

  if ! command -v timeout > "$EXAM_DIR/logs/required-commands.log" 2>&1 \
      || ! command -v python3 >> "$EXAM_DIR/logs/required-commands.log" 2>&1; then
    fail_preparation "필수 명령(timeout/python3)을 찾을 수 없습니다."
    return 1
  fi
  # PREPARING is visible before any repair begins. Validate the running cluster
  # and its immutable version/image contract before an addon repair can mutate it.
  if ! ( require_cluster_readonly ) > "$EXAM_DIR/logs/cluster-preparation.log" 2>&1; then
    fail_preparation "클러스터 연결 실패 (로그: $EXAM_DIR/logs/cluster-preparation.log)"
    return 1
  fi
  if ! cluster_matches_version_lock >> "$EXAM_DIR/logs/cluster-preparation.log" 2>&1; then
    fail_preparation "클러스터가 versions.lock.yaml과 일치하지 않습니다."
    return 1
  fi
  # require_cluster may call die while repairing addons; isolate it and convert
  # every failure into an auditable INVALID run.
  if ! ( require_cluster ) >> "$EXAM_DIR/logs/cluster-preparation.log" 2>&1; then
    fail_preparation "클러스터 애드온 준비 실패 (로그: $EXAM_DIR/logs/cluster-preparation.log)"
    return 1
  fi
  if ! verify_cluster_cleanup_invariants \
      >> "$EXAM_DIR/logs/cluster-preparation.log" 2>&1; then
    fail_preparation "클러스터 baseline이 깨져 있습니다. node/scheduler/addon 상태를 복구한 뒤 다시 시작하세요."
    return 1
  fi
  if preparation_cancel_requested; then
    fail_preparation "사용자가 클러스터 준비 중 모의고사 취소를 요청했습니다."
    return 1
  fi

  if ! bash "$PLANNER" --seed "$seed" \
      --questions-out "$EXAM_DIR/questions" \
      --setup-order-out "$EXAM_DIR/setup-order" \
      > "$EXAM_DIR/logs/planner.log" 2>&1; then
    fail_preparation "compatible form 생성 실패 (seed: $seed)"
    return 1
  fi
  if ! bash "$PLANNER" --validate "$EXAM_DIR/questions" \
      >> "$EXAM_DIR/logs/planner.log" 2>&1; then
    fail_preparation "생성된 form 검증 실패 (seed: $seed)"
    return 1
  fi
  if ! verify_form_runtime_requirements "$EXAM_DIR/questions" \
      >> "$EXAM_DIR/logs/planner.log" 2>&1; then
    fail_preparation "선택 form의 node drain runtime 요구조건을 충족하지 못했습니다."
    return 1
  fi
  if preparation_cancel_requested; then
    fail_preparation "사용자가 form 생성 중 모의고사 취소를 요청했습니다."
    return 1
  fi

  printf '\n%s\n' "${C_BLD}모의고사 환경을 구성합니다 (17문제, seed: $seed)...${C_RST}"
  while IFS= read -r id; do
    i=$((i + 1))
    printf '  [%2d/17] %s 환경 구성 중...\n' "$i" "$id"
    qdir="$(qdir_of "$id")" || {
      fail_preparation "$id 문제 디렉터리를 찾을 수 없습니다."
      return 1
    }
    printf '%s\n' "$id" >> "$EXAM_DIR/setup-attempted" \
      || die "setup 추적 파일을 갱신할 수 없습니다."
    local setup_rc=0
    if run_bounded "$SETUP_TIMEOUT_SEC" bash "$qdir/setup.sh" \
        > "$EXAM_DIR/logs/$id-setup.log" 2>&1; then
      setup_rc=0
    else
      setup_rc=$?
    fi
    if [ "$setup_rc" -eq 124 ] || [ "$setup_rc" -eq 137 ]; then
      fail_preparation "$id setup timeout (${SETUP_TIMEOUT_SEC}초)"
      return 1
    fi
    if [ "$setup_rc" -ne 0 ]; then
      fail_preparation "$id setup 실패 (exit=$setup_rc)"
      return 1
    fi
    state_clear "$id"
    if preparation_cancel_requested; then
      fail_preparation "사용자가 $id setup 후 모의고사 취소를 요청했습니다."
      return 1
    fi
  done < "$EXAM_DIR/setup-order"

  if ! preflight_form; then
    local preflight_reason
    preflight_reason="$(cat "$EXAM_DIR/preflight-error" 2>/dev/null || printf '전체 preflight 실패')"
    fail_preparation "$preflight_reason"
    return 1
  fi

  if preparation_cancel_requested; then
    fail_preparation "사용자가 시험 준비 중 모의고사 취소를 요청했습니다."
    return 1
  fi

  # Mark the tiny commit phase before the final cancellation check. An abort
  # that sees this marker will wait for RUNNING and use the normal abort path;
  # an earlier request is guaranteed to be observed here.
  if ! mkdir "$EXAM_DIR/start-commit" 2>/dev/null; then
    fail_preparation "내부 오류: 시험 시작 commit marker를 만들 수 없습니다."
    return 1
  fi
  if preparation_cancel_requested; then
    fail_preparation "사용자가 시험 시작 직전 모의고사 취소를 요청했습니다."
    return 1
  fi

  # The clock starts only after every setup and every preflight check succeeds.
  started="$(exam_now)"
  deadline=$((started + DURATION_MIN * 60))
  if ! printf '%s\n' "$started" > "$EXAM_DIR/started"; then
    fail_preparation "시험 시작 시각을 기록할 수 없습니다."
    return 1
  fi
  if ! printf '%s\n' "$deadline" > "$EXAM_DIR/deadline"; then
    fail_preparation "시험 deadline을 기록할 수 없습니다."
    return 1
  fi
  transition_state RUNNING
  unlock_exam_command

  printf '\n%s\n\n' "${C_GRN}${C_BLD}══ 모의고사 시작! 제한시간 ${DURATION_MIN}분 ══${C_RST}"
  cmd_status
  cat <<EOF
사용법:
  cka exam question <n>   n번 문제 지문 보기 (예: cka exam question 3)
  cka exam status         남은 시간·문제 목록
  cka exam finish         제한시간 내 제출 및 채점

재현용 seed: $seed
EOF
}

print_question_list() {
  printf '\n%-5s %-8s %-4s %s\n' "NO" "ID" "PTS" "TITLE"
  printf '%s\n' "──────────────────────────────────────────────────"
  local i=0 id qdir
  while IFS= read -r id; do
    i=$((i + 1))
    qdir="$(qdir_of "$id")"
    printf 'q%-4s %-8s %-4s %s\n' "$i" "$id" "$(meta_get "$qdir" points)" "$(meta_get "$qdir" title)"
  done < "$EXAM_DIR/questions"
  printf '\n'
}

cmd_status() {
  local state rem reason status_lock=0
  state="$(exam_state)"
  case "$state" in
    PREPARING)
      printf '\n%s\n' "${C_YLW}${C_BLD}모의고사 환경을 준비 중입니다.${C_RST}"
      return 0
      ;;
    RUNNING)
      acquire_exam_lock status
      status_lock=1
      sync_deadline_state || true
      state="$(exam_state)"
      case "$state" in
        RUNNING|SEALED) ;;
        GRADING)
          printf '\n%s\n' "${C_YLW}${C_BLD}모의고사를 채점 중입니다.${C_RST}"
          unlock_exam_command
          return 0
          ;;
        *) die "진행 중인 모의고사가 없습니다. 'cka exam' 으로 시작하세요." ;;
      esac
      ;;
    SEALED) ;;
    GRADING)
      printf '\n%s\n' "${C_YLW}${C_BLD}모의고사를 채점 중입니다.${C_RST}"
      return 0
      ;;
    *) die "진행 중인 모의고사가 없습니다. 'cka exam' 으로 시작하세요." ;;
  esac

  if [ "$state" = SEALED ]; then
    reason="$(cat "$EXAM_DIR/seal-reason" 2>/dev/null || printf UNKNOWN)"
    if [ "$reason" = TIMEOUT ]; then
      printf '\n%s\n' "${C_RED}${C_BLD}남은 시간: 00:00:00 — 시간 만료, 답안이 봉인되었습니다. 'cka exam finish'로 채점하세요.${C_RST}"
    else
      printf '\n%s\n' "${C_YLW}${C_BLD}답안이 봉인되었습니다 ($reason).${C_RST}"
    fi
  else
    rem="$(remaining_seconds)" || die "시험 deadline을 읽을 수 없습니다."
    printf '\n%s\n' "${C_BLD}남은 시간: $(fmt_mmss "$rem")${C_RST}"
  fi
  print_question_list
  [ "$status_lock" -eq 0 ] || unlock_exam_command
}

cmd_question() {
  acquire_exam_lock question
  [ "$(exam_state)" = RUNNING ] || die "풀이 중인 모의고사가 없습니다."
  sync_deadline_state || true
  [ "$(exam_state)" = RUNNING ] \
    || die "제한시간이 끝나 답안이 봉인되었습니다. 'cka exam finish'로 채점하세요."
  local id qdir n
  id="$(qid_of_num "${1:-}")"
  [ -n "$id" ] || die "문제 번호가 올바르지 않습니다 (q1~q17)."
  qdir="$(qdir_of "$id")"
  n="${1#q}"
  printf '\n%s\n\n' "${C_BLD}═════ Question ${n}/17 | $(meta_get "$qdir" points) points ═════${C_RST}"
  cat "$qdir/question.md"
  printf '\n'
  unlock_exam_command
}

cmd_finish() {
  acquire_exam_lock finish
  local state reason timed_out=0 invalid=0
  state="$(exam_state)"
  case "$state" in
    RUNNING)
      sync_deadline_state || true
      if [ "$(exam_state)" = RUNNING ]; then
        if ! seal_exam SUBMITTED; then :; fi
      fi
      ;;
    SEALED) ;;
    *) die "제출할 모의고사가 없습니다 (현재 상태: $state)." ;;
  esac
  reason="$(cat "$EXAM_DIR/seal-reason" 2>/dev/null || printf UNKNOWN)"
  [ "$reason" = TIMEOUT ] && timed_out=1
  [ "$reason" = STATE_ERROR ] && invalid=1
  transition_state GRADING

  printf '\n%s\n' "${C_BLD}채점 중... (문제당 수 초)${C_RST}"
  declare -A DOM_EARNED DOM_MAX
  local total_earned=0 total_max=0 i=0 id qdir dom st e m expected grade_rc
  local detail=""
  while IFS= read -r id; do
    i=$((i + 1))
    qdir="$(qdir_of "$id")"
    dom="$(meta_get "$qdir" domain)"
    expected="$(meta_get "$qdir" points)"
    state_clear "$id"
    if run_bounded "$GRADE_TIMEOUT_SEC" bash "$qdir/grade.sh" \
        > "$EXAM_DIR/logs/$id-final-grade.log" 2>&1; then
      grade_rc=0
    else
      grade_rc=$?
    fi
    st="$(state_get "$id")"
    # grade_finish: 0=PASS, 1=valid FAIL, 2=INVALID. A partial score must remain
    # a candidate result rather than invalidating the whole form.
    if [ "$grade_rc" -ne 0 ] && [ "$grade_rc" -ne 1 ]; then
      e=0; m="${expected:-0}"; invalid=1
      [[ "$m" =~ ^[1-9][0-9]*$ ]] || m=0
      if [ "$grade_rc" -eq 124 ] || [ "$grade_rc" -eq 137 ]; then
        printf 'final grader timeout after %ss\n' "$GRADE_TIMEOUT_SEC" \
          >> "$EXAM_DIR/logs/$id-final-grade.log"
      else
        printf 'final grader exited %s\n' "$grade_rc" \
          >> "$EXAM_DIR/logs/$id-final-grade.log"
      fi
    elif parse_grade_state "$st" && [[ "$expected" =~ ^[1-9][0-9]*$ ]] && [ "$PARSED_MAX" -eq "$expected" ]; then
      e="$PARSED_EARNED"; m="$PARSED_MAX"
    else
      e=0; m="${expected:-0}"; invalid=1
      [[ "$m" =~ ^[1-9][0-9]*$ ]] || m=0
    fi
    total_earned=$((total_earned + e)); total_max=$((total_max + m))
    DOM_EARNED[$dom]=$(( ${DOM_EARNED[$dom]:-0} + e ))
    DOM_MAX[$dom]=$(( ${DOM_MAX[$dom]:-0} + m ))
    detail+="$(printf 'q%-4s %-8s %3s/%-3s %s' "$i" "$id" "$e" "$m" "$(meta_get "$qdir" title)")"$'\n'
  done < "$EXAM_DIR/questions"

  local pct=0 outcome result_file result_stem overtime="" cleanup_failed=0
  [ "$total_max" -gt 0 ] && pct=$(( total_earned * 100 / total_max )) || invalid=1
  [ "$timed_out" -eq 1 ] && overtime="  (시간 만료 후 채점)"

  printf '\n%s\n' "${C_BLD}══════════════ 모의고사 성적표${overtime} ══════════════${C_RST}"
  printf '%s\n' "$detail"
  printf '%s\n' "──────────────────────────────────────────────────"
  printf '%s\n' "${C_BLD}도메인별:${C_RST}"
  local d dpct mark
  for d in troubleshooting cluster-architecture services-networking workloads-scheduling storage; do
    [ -n "${DOM_MAX[$d]:-}" ] || continue
    dpct=$(( ${DOM_EARNED[$d]} * 100 / ${DOM_MAX[$d]} ))
    mark=""; [ "$dpct" -lt "$PASS_PCT" ] && mark="  ${C_YLW}⚠ 취약${C_RST}"
    printf '  %-24s %3d/%-3d (%d%%)%s\n' "$d" "${DOM_EARNED[$d]}" "${DOM_MAX[$d]}" "$dpct" "$mark"
  done
  printf '%s\n' "──────────────────────────────────────────────────"

  if ! mkdir -p "$RESULT_DIR"; then
    transition_state INVALID
    die "시험 결과 디렉터리를 만들 수 없습니다: $RESULT_DIR"
  fi
  result_stem="$(date +%Y%m%d-%H%M%S)-$(cat "$EXAM_DIR/run-id" 2>/dev/null || printf $$)"
  result_file="$RESULT_DIR/$result_stem.txt"
  if ! archive_submissions "$RESULT_DIR/$result_stem-files"; then
    invalid=1
  fi
  if ! cleanup_exam_environment; then
    cleanup_failed=1
    invalid=1
  fi

  if [ "$invalid" -eq 1 ]; then
    outcome=INVALID
    if [ "$cleanup_failed" -eq 1 ]; then
      printf '%s\n\n' "${C_RED}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 판정 무효 (환경 정리 실패)${C_RST}"
    else
      printf '%s\n\n' "${C_RED}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 판정 무효 (grader 오류/timeout)${C_RST}"
    fi
  elif [ "$timed_out" -eq 1 ]; then
    outcome=FAIL
    printf '%s\n\n' "${C_RED}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 불합격 (제한시간 초과)${C_RST}"
  elif score_is_pass "$pct" 0 0; then
    outcome=PASS
    printf '%s\n\n' "${C_GRN}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 합격 (기준 ${PASS_PCT}%)${C_RST}"
  else
    outcome=FAIL
    printf '%s\n\n' "${C_RED}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 불합격 (기준 ${PASS_PCT}%)${C_RST}"
  fi
  printf '%s\n\n' "오답 복습: 각 문제의 정답지는 'cka solution <id>' 로 확인하세요."

  {
    printf 'date: %s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'result: %s\n' "$outcome"
    printf 'score: %s/%s (%s%%)\n' "$total_earned" "$total_max" "$pct"
    printf 'timed_out: %s\n' "$timed_out"
    printf 'cleanup_failed: %s\n' "$cleanup_failed"
    printf 'seed: %s\n\n' "$(cat "$EXAM_DIR/seed")"
    printf '%s\n' "$detail"
  } > "$result_file" || {
    transition_state INVALID
    die "시험 결과 파일을 쓸 수 없습니다: $result_file"
  }
  if ! printf '%s\n' "$result_file" > "$EXAM_DIR/result"; then
    transition_state INVALID
    die "시험 결과 경로를 기록할 수 없습니다."
  fi
  if [ "$invalid" -eq 1 ]; then
    transition_state INVALID
  else
    transition_state ARCHIVED
  fi
  unlock_exam_command
}

cmd_abort() {
  local state request_rc=1 i
  state="$(exam_state)"
  if [ "$state" = PREPARING ]; then
    request_preparation_cancel
    request_rc=$?
    if [ "$request_rc" -eq 0 ]; then
      ok "준비 중인 모의고사에 취소를 요청했습니다. 현재 setup이 끝나면 안전하게 정리됩니다."
      return 0
    fi
    if [ "$request_rc" -eq 2 ]; then
      for i in $(seq 1 50); do
        [ "$(exam_state)" = PREPARING ] || break
        sleep 0.1
      done
    fi
  fi
  acquire_exam_lock abort
  state="$(exam_state)"
  case "$state" in
    PREPARING)
      printf '%s\n' ABORTED > "$EXAM_DIR/seal-reason" \
        || die "중단 사유를 기록할 수 없습니다."
      transition_state SEALED
      ;;
    RUNNING) if ! seal_exam ABORTED; then :; fi ;;
    SEALED) ;;
    *) die "중단할 모의고사가 없습니다 (현재 상태: $state)." ;;
  esac
  local cleanup_ok=0
  if cleanup_exam_environment; then
    cleanup_ok=1
    transition_state ARCHIVED
  else
    archive_invalid_run "모의고사 중단 후 환경 정리에 실패했습니다."
    transition_state INVALID
  fi
  unlock_exam_command
  if [ "$cleanup_ok" -eq 1 ]; then
    ok "모의고사를 중단하고 환경을 정리했습니다."
  else
    err "모의고사는 중단했지만 환경 정리에 실패했습니다. cleanup 로그를 확인하세요."
    return 1
  fi
}

main() {
  local command="${1:-start}"
  [ "$#" -gt 0 ] && shift || true
  case "$command" in
    start)    cmd_start "$@" ;;
    status)   cmd_status ;;
    question) cmd_question "${1:-}" ;;
    finish)   cmd_finish ;;
    abort)    cmd_abort ;;
    __verify-cleanup-invariants)
      [[ "${1:-}" =~ ^[0-9]+$ ]] \
        || die "내부 cleanup deadline이 유효하지 않습니다."
      verify_cluster_cleanup_invariants "$1"
      ;;
    *) die "사용법: cka exam [start [--seed <seed>]|status|question <n>|finish|abort]" ;;
  esac
}

if [ "${CKA_EXAM_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
