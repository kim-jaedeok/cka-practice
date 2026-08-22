#!/usr/bin/env bash
# Opt-in destructive live test. It allocates its own disposable controller cell.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

[ "${CKA_CONTROLLER_LIVE:-0}" = 1 ] \
  || die "set CKA_CONTROLLER_LIVE=1 to run the opt-in controller live test"

QID=""
case "${1:-}" in
  --only)
    [ "$#" -eq 2 ] || die "usage: $0 --only ca-09|ca-13|sn-05"
    QID="$2"
    ;;
  *) die "usage: $0 --only ca-09|ca-13|sn-05" ;;
esac
case "$QID" in ca-09|ca-13|sn-05) ;; *) die "unsupported live-test question: $QID" ;; esac

case "$QID" in
  ca-09|ca-13) QDIR="$ROOT/questions/cluster-architecture/$QID" ;;
  sn-05) QDIR="$ROOT/questions/services-networking/$QID" ;;
esac

read_timeout() {
  local key="$1" value
  value="$(meta_get "$QDIR" "$key")"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || die "$QID has an invalid $key: ${value:-missing}"
  printf '%s' "$value"
}

SETUP_TIMEOUT="$(read_timeout setup_timeout_seconds)"
GRADE_TIMEOUT="$(read_timeout grade_timeout_seconds)"
CLEANUP_TIMEOUT="$SETUP_TIMEOUT"
EXPECTED_POINTS="$(meta_get "$QDIR" points)"
[[ "$EXPECTED_POINTS" =~ ^[1-9][0-9]*$ ]] \
  || die "$QID has invalid points metadata: ${EXPECTED_POINTS:-missing}"

run_cleanup() {
  timeout --foreground "${CLEANUP_TIMEOUT}s" "$ROOT/cka" cleanup "$QID"
}

cleanup_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if ! run_cleanup; then
    warn "$QID cleanup failed or exceeded ${CLEANUP_TIMEOUT}s"
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap 'exit 130' INT TERM
trap cleanup_on_exit EXIT

timeout --foreground "${SETUP_TIMEOUT}s" "$ROOT/cka" start "$QID" \
  || die "$QID setup failed or exceeded ${SETUP_TIMEOUT}s"

timeout --foreground "${GRADE_TIMEOUT}s" "$ROOT/cka" grade "$QID" >/dev/null 2>&1 \
  || true
state="$(state_get "$QID")"
[[ "$state" =~ ^graded:([0-9]+)/([0-9]+)$ ]] \
  || die "$QID pre-solve grade produced invalid state: $state"
pre_earned="${BASH_REMATCH[1]}"
pre_maximum="${BASH_REMATCH[2]}"
[ "$pre_maximum" = "$EXPECTED_POINTS" ] \
  || die "$QID pre-solve maximum $pre_maximum differs from metadata $EXPECTED_POINTS"
[ "$pre_earned" -lt "$pre_maximum" ] \
  || die "$QID was already fully solved before the reference solution"

timeout --foreground "${SETUP_TIMEOUT}s" bash "$QDIR/solve.sh" \
  || die "$QID reference solution failed or exceeded ${SETUP_TIMEOUT}s"
timeout --foreground "${GRADE_TIMEOUT}s" "$ROOT/cka" grade "$QID" >/dev/null 2>&1 \
  || die "$QID solution grader failed or exceeded ${GRADE_TIMEOUT}s"

state="$(state_get "$QID")"
earned="${state#graded:}"; maximum="${earned#*/}"; earned="${earned%%/*}"
[[ "$state" =~ ^graded:[0-9]+/[0-9]+$ ]] && [ "$earned" = "$maximum" ] \
  && [ "$maximum" = "$EXPECTED_POINTS" ] \
  || die "$QID live score was $state (expected maximum $EXPECTED_POINTS)"
run_cleanup || die "$QID cleanup failed or exceeded ${CLEANUP_TIMEOUT}s"
trap - EXIT INT TERM
ok "$QID offline controller live contract passed"
