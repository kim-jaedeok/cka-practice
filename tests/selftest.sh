#!/usr/bin/env bash
# 정답지·채점기 정합성 검증
#   각 문제에 대해: setup → grade(만점이면 안 됨) → solve(모범답안) → grade(만점이어야 함) → teardown/cleanup
# 사용법:
#   tests/selftest.sh                  # 전체 40문제
#   tests/selftest.sh --domain storage # 특정 도메인만
#   tests/selftest.sh --only st-01     # 특정 문제만
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DOMAIN_ORDER=(storage workloads-scheduling services-networking cluster-architecture troubleshooting)
ONLY="" DOMAIN=""
case "${1:-}" in
  --only)   ONLY="${2:-}" ;;
  --domain) DOMAIN="${2:-}" ;;
esac

require_cluster

parse_score() { # state "graded:E/M" → "E M"
  local st="$1" e m
  e="${st#graded:}"; m="${e#*/}"; e="${e%%/*}"
  case "$e" in ''|*[!0-9]*) e=-1 ;; esac
  case "$m" in ''|*[!0-9]*) m=-1 ;; esac
  echo "$e $m"
}

PASS=0; FAIL=0; FAILED_IDS=()

run_one() {
  local qdir="$1" id pre post e0 m0 e1 m1
  id="$(basename "$qdir")"
  printf '%s\n' "${C_BLD}══ selftest: $id ══${C_RST}"

  if ! bash "$qdir/setup.sh" > "/tmp/selftest-$id-setup.log" 2>&1; then
    err "$id: setup 실패 (/tmp/selftest-$id-setup.log)"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:setup"); return
  fi

  bash "$qdir/grade.sh" > "/tmp/selftest-$id-pre.log" 2>&1 || true
  read -r e0 m0 <<< "$(parse_score "$(state_get "$id")")"

  if ! bash "$qdir/solve.sh" > "/tmp/selftest-$id-solve.log" 2>&1; then
    err "$id: solve 실패 (/tmp/selftest-$id-solve.log)"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:solve")
  else
    bash "$qdir/grade.sh" > "/tmp/selftest-$id-post.log" 2>&1 || true
    read -r e1 m1 <<< "$(parse_score "$(state_get "$id")")"

    if [ "$e1" -ge 0 ] && [ "$e1" -eq "$m1" ]; then
      if [ "$e0" -eq "$m0" ]; then
        warn "$id: setup 직후에 이미 만점 ($e0/$m0) — 문제 성립 안 함"
        FAIL=$((FAIL+1)); FAILED_IDS+=("$id:trivial")
      else
        ok "$id: pre $e0/$m0 → post $e1/$m1 만점 ✓"
        PASS=$((PASS+1))
      fi
    else
      err "$id: solve 후에도 만점 아님 ($e1/$m1) — /tmp/selftest-$id-post.log"
      FAIL=$((FAIL+1)); FAILED_IDS+=("$id:grade")
    fi
  fi

  [ -f "$qdir/teardown.sh" ] && bash "$qdir/teardown.sh" >/dev/null 2>&1 || true
  cleanup_question "$id" >/dev/null 2>&1 || true
  state_clear "$id"
}

for d in "${DOMAIN_ORDER[@]}"; do
  [ -n "$DOMAIN" ] && [ "$d" != "$DOMAIN" ] && continue
  for qdir in "$CKA_ROOT/questions/$d"/*/; do
    [ -d "$qdir" ] || continue
    [ -n "$ONLY" ] && [ "$(basename "$qdir")" != "$ONLY" ] && continue
    run_one "$qdir"
  done
done

printf '\n%s\n' "${C_BLD}══ selftest 결과: 통과 $PASS / 실패 $FAIL ══${C_RST}"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "실패 목록: ${FAILED_IDS[*]}"
  exit 1
fi
