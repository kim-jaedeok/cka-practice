#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=""
expected_run_id=""
expected_ssh_run_id=""
runner=""
ready_file=""
seal_script=""

fail() { printf 'deadline watcher: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-dir) [ "$#" -ge 2 ] || fail '--state-dir needs a value'; state_dir="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || fail '--run-id needs a value'; expected_run_id="$2"; shift 2 ;;
    --ssh-run-id) [ "$#" -ge 2 ] || fail '--ssh-run-id needs a value'; expected_ssh_run_id="$2"; shift 2 ;;
    --runner) [ "$#" -ge 2 ] || fail '--runner needs a value'; runner="$2"; shift 2 ;;
    --ready-file) [ "$#" -ge 2 ] || fail '--ready-file needs a value'; ready_file="$2"; shift 2 ;;
    --seal-script) [ "$#" -ge 2 ] || fail '--seal-script needs a value'; seal_script="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$state_dir" in /*) ;; *) fail 'state directory must be absolute' ;; esac
[[ "$expected_run_id" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || fail 'invalid exam run ID'
case "$expected_ssh_run_id" in
  ''|*[!a-z0-9-]*|-*|*-) fail 'invalid SSH run ID' ;;
esac
[ "${#expected_ssh_run_id}" -le 32 ] || fail 'SSH run ID is too long'
[ -f "$runner" ] && [ ! -L "$runner" ] || fail 'runner must be a regular non-symlink file'
[ -f "$seal_script" ] && [ ! -L "$seal_script" ] \
  || fail 'seal script must be a regular non-symlink file'
exam_dir="$state_dir/exam"

[ -r "$exam_dir/run-id" ] || fail 'exam run ID is missing'
[ "$(tr -d '\r\n' < "$exam_dir/run-id")" = "$expected_run_id" ] \
  || fail 'exam run ID does not match'
[ -r "$exam_dir/ssh-run-id" ] || fail 'SSH run ID is missing'
[ "$(tr -d '\r\n' < "$exam_dir/ssh-run-id")" = "$expected_ssh_run_id" ] \
  || fail 'SSH run ID does not match'
state="$(tr -d '\r\n' < "$exam_dir/state" 2>/dev/null || true)"
case "$state" in
  PREPARING|RUNNING) ;;
  *) fail 'exam is not preparing or running' ;;
esac
deadline="$(tr -d '\r\n' < "$exam_dir/deadline" 2>/dev/null || true)"
[[ "$deadline" =~ ^[0-9]+$ ]] || fail 'deadline is missing or invalid'

process_start_time() {
  local pid="$1" stat_line rest
  [ -r "/proc/$pid/stat" ] || return 1
  stat_line="$(< "/proc/$pid/stat")" || return 1
  case "$stat_line" in *') '*) ;; *) return 1 ;; esac
  rest="${stat_line##*) }"
  set -- $rest
  [ "$#" -ge 20 ] && [[ "${20}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${20}"
}
watcher_start_time="$(process_start_time "$$")" \
  || fail 'cannot read watcher process identity'

run_record_matches() {
  local path="$1" expected="$2" actual
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  actual="$(cat -- "$path")" || return 1
  [ "$actual" = "$expected" ]
}

if [ -n "$ready_file" ]; then
  case "$ready_file" in "$exam_dir"/*) ;; *) fail 'ready file must stay inside the exam directory' ;; esac
  [ ! -e "$ready_file" ] && [ ! -L "$ready_file" ] || fail 'ready file already exists'
  ready_tmp="${ready_file}.$$"
  ( umask 077; printf '%s %s %s %s\n' "$$" "$expected_run_id" \
      "$expected_ssh_run_id" "$watcher_start_time" > "$ready_tmp" ) \
    || fail 'cannot write readiness record'
  mv -f "$ready_tmp" "$ready_file" || fail 'cannot publish readiness record'
fi

remove_own_record() {
  local recorded_pid="" recorded_run_id="" recorded_ssh_run_id=""
  local recorded_start_time="" extra=""
  [ -r "$exam_dir/ssh-deadline-watcher" ] || return 0
  IFS=' ' read -r recorded_pid recorded_run_id recorded_ssh_run_id \
    recorded_start_time extra \
    < "$exam_dir/ssh-deadline-watcher" || return 0
  if [ "$recorded_pid" = "$$" ] && [ "$recorded_run_id" = "$expected_run_id" ] \
      && [ "$recorded_ssh_run_id" = "$expected_ssh_run_id" ] \
      && [ "$recorded_start_time" = "$watcher_start_time" ] && [ -z "$extra" ]; then
    rm -f -- "$exam_dir/ssh-deadline-watcher"
  fi
}
trap remove_own_record EXIT
hard_stopped=0

while :; do
  if [ ! -r "$exam_dir/run-id" ] \
      || [ "$(tr -d '\r\n' < "$exam_dir/run-id")" != "$expected_run_id" ]; then
    if [ "$hard_stopped" -eq 0 ] \
        && bash "$seal_script" --run-id "$expected_ssh_run_id"; then
      hard_stopped=1
    fi
    [ "$hard_stopped" -eq 1 ] && exit 1
    sleep 1
    continue
  fi
  state="$(tr -d '\r\n' < "$exam_dir/state" 2>/dev/null || true)"
  case "$state" in
    PREPARING|RUNNING) ;;
    SEALED|GRADING|ARCHIVED|INVALID)
      run_record_matches "$exam_dir/ssh-environment-disposed" \
        "$expected_ssh_run_id" && exit 0
      if [ "$hard_stopped" -eq 0 ] \
          && bash "$seal_script" --run-id "$expected_ssh_run_id"; then
        hard_stopped=1
      fi
      [ "$hard_stopped" -eq 1 ] && exit 0
      sleep 1
      continue
      ;;
    *)
      if [ "$hard_stopped" -eq 0 ] \
          && bash "$seal_script" --run-id "$expected_ssh_run_id"; then
        hard_stopped=1
      fi
      [ "$hard_stopped" -eq 1 ] && exit 1
      sleep 1
      continue
      ;;
  esac
  now="$(date +%s)"
  if [ "$now" -ge "$deadline" ]; then
    if [ "$hard_stopped" -eq 0 ]; then
      if bash "$seal_script" --run-id "$expected_ssh_run_id"; then
        hard_stopped=1
      fi
    fi
    # A concurrent finish/status can temporarily own the exam lock. Retry
    # state transition and answer recovery until that command finishes. The
    # target/base hard stop above never waits for the runner lock.
    if CKA_STATE_DIR="$state_dir" bash "$runner" __ssh-deadline \
        "$expected_run_id" "$expected_ssh_run_id" \
        && [ "$hard_stopped" -eq 1 ]; then
      exit 0
    fi
    sleep 1
    continue
  fi
  remaining=$((deadline - now))
  [ "$remaining" -le 30 ] || remaining=30
  [ "$remaining" -ge 1 ] || remaining=1
  sleep "$remaining"
done
