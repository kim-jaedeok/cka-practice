#!/usr/bin/env bash
# Expensive opt-in: builds disposable kubeadm cells, never shared kind-cka.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$CKA_ROOT/lib/common.sh"
source "$CKA_ROOT/cluster/cells/kubeadm/package-cache.sh"

if [ "${CKA_RUN_KUBEADM_LIVE_TESTS:-0}" != 1 ]; then
  printf '%s\n' "SKIP kubeadm live tests (set CKA_RUN_KUBEADM_LIVE_TESTS=1)"
  # A required live gate must not be mistaken for a passing execution when
  # its explicit opt-in was omitted.
  exit 77
fi
[ "${CKA_ENABLE_KUBEADM_CELLS:-0}" = 1 ] \
  || die "CKA_ENABLE_KUBEADM_CELLS=1 is required"

TARGETS=(ca-12 ca-11 ca-06)
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --only ] \
    || die "usage: $0 [--only ca-12|ca-11|ca-06]"
  case "$2" in ca-12|ca-11|ca-06) TARGETS=("$2") ;; *)
    die "unsupported kubeadm live-test question: $2" ;;
  esac
fi

ACTIVE_QID=""
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$ACTIVE_QID" ]; then
    "$CKA_ROOT/cka" cleanup "$ACTIVE_QID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

run_question() { # <qid> <expected-points>
  local qid="$1" expected="$2" qdir initial final
  ACTIVE_QID="$qid"
  qdir="$(qdir_of "$qid")" || die "missing question: $qid"
  "$CKA_ROOT/cka" start "$qid" >/dev/null
  "$CKA_ROOT/cka" grade "$qid" >/dev/null 2>&1 || true
  initial="$(state_get "$qid")"
  case "$initial" in
    graded:*) [ "$initial" != "graded:$expected/$expected" ] \
      || die "$qid baseline unexpectedly has full credit" ;;
    *) die "$qid baseline grader was not valid: $initial" ;;
  esac
  bash "$qdir/solve.sh"
  "$CKA_ROOT/cka" grade "$qid" >/dev/null
  final="$(state_get "$qid")"
  [ "$final" = "graded:$expected/$expected" ] \
    || die "$qid canonical live score was $final"
  if [ "$qid" = ca-11 ]; then
    bash "$CKA_ROOT/cluster/cells/kubeadm/failover-test.sh" ca-11
  fi
  "$CKA_ROOT/cka" cleanup "$qid" >/dev/null
  ACTIVE_QID=""
}

kubeadm_package_cache_verify \
  || die "cache exact kubeadm upgrade packages first: cluster/cells/kubeadm/cache-packages.sh"
for qid in "${TARGETS[@]}"; do
  case "$qid" in
    ca-12) run_question "$qid" 10 ;;
    ca-11) run_question "$qid" 12 ;;
    ca-06) run_question "$qid" 8 ;;
  esac
done

trap - EXIT INT TERM
printf '%s\n' "PASS kubeadm live gate: ${TARGETS[*]}"
