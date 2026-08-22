#!/usr/bin/env bash
# 정답지·채점기 정합성 검증
#   각 문제에 대해: setup → grade(만점이면 안 됨) → solve(모범답안) → grade(만점이어야 함) → teardown/cleanup
# 사용법:
#   tests/selftest.sh                  # 공유 클러스터 문제
#   tests/selftest.sh --include-disposable # 52문제 전체(고비용 opt-in)
#   tests/selftest.sh --domain storage # 특정 도메인만
#   tests/selftest.sh --only st-01     # 특정 문제만
#   tests/selftest.sh --contract-only  # 클러스터 없이 공통/static 계약만
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/question-runtime.sh"

DOMAIN_ORDER=(storage workloads-scheduling services-networking cluster-architecture troubleshooting)
ONLY="" DOMAIN="" CONTRACT_ONLY=0 RUN_CONTRACT=1 INCLUDE_DISPOSABLE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)          [ "$#" -ge 2 ] || die "--only requires an id"; ONLY="$2"; shift 2 ;;
    --domain)        [ "$#" -ge 2 ] || die "--domain requires a name"; DOMAIN="$2"; shift 2 ;;
    --contract-only) CONTRACT_ONLY=1; shift ;;
    --skip-contract) RUN_CONTRACT=0; shift ;;
    --include-disposable) INCLUDE_DISPOSABLE=1; shift ;;
    *) die "사용법: tests/selftest.sh [--only ID|--domain DOMAIN] [--include-disposable] [--contract-only|--skip-contract]" ;;
  esac
done

if [ "$RUN_CONTRACT" -eq 1 ]; then
  bash "$SCRIPT_DIR/contract-test.sh" || exit 1
fi
[ "$CONTRACT_ONLY" -eq 1 ] && exit 0

parse_result() { # state → "PASS|FAIL|INVALID E M"
  local st="$1" e m status
  case "$st" in
    invalid:*) printf '%s\n' "INVALID -1 -1"; return ;;
    graded:*)  : ;;
    *)         printf '%s\n' "INVALID -1 -1"; return ;;
  esac
  e="${st#graded:}"; m="${e#*/}"; e="${e%%/*}"
  case "$e" in ''|*[!0-9]*) e=-1 ;; esac
  case "$m" in ''|*[!0-9]*) m=-1 ;; esac
  if [ "$e" -lt 0 ] || [ "$m" -le 0 ]; then
    status=INVALID
  elif [ "$e" -eq "$m" ]; then
    status=PASS
  else
    status=FAIL
  fi
  printf '%s %s %s\n' "$status" "$e" "$m"
}

PASS=0; FAIL=0; SKIP=0; FAILED_IDS=()

cleanup_one() { # cleanup_one <qdir> <id>
  local qdir="$1" id="$2" failed=0
  question_runtime_cleanup "$id" "$qdir" >/dev/null 2>&1 || failed=1
  state_clear "$id" || failed=1
  return "$failed"
}

run_one() {
  local qdir="$1" id e0 m0 e1 m1 s0 s1 hook hs he hm
  id="$(basename "$qdir")"
  printf '%s\n' "${C_BLD}══ selftest: $id ══${C_RST}"

  if ! question_runtime_start "$id" "$qdir" > "/tmp/selftest-$id-setup.log" 2>&1; then
    err "$id: setup 실패 (/tmp/selftest-$id-setup.log)"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:setup")
    cleanup_one "$qdir" "$id" || FAILED_IDS+=("$id:cleanup-after-setup-failure")
    return
  fi

  question_runtime_grade "$id" "$qdir" > "/tmp/selftest-$id-pre.log" 2>&1 || true
  read -r s0 e0 m0 <<< "$(parse_result "$(state_get "$id")")"

  if [ "$s0" = INVALID ]; then
    err "$id: setup 직후 채점이 INVALID — 랩/채점 인프라 확인 (/tmp/selftest-$id-pre.log)"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:invalid-pre")
    cleanup_one "$qdir" "$id" || FAILED_IDS+=("$id:cleanup-after-invalid-pre")
    return
  fi

  # 향후 문제별 계약 fixture가 생기면 자동 실행한다. near-miss는 부분 점수만,
  # alternative은 모범답안과 다른 경로로 만점을 받아야 한다.
  for hook in near-miss near-miss-port near-miss-source near-miss-tamper alternative; do
    [ -f "$qdir/$hook.sh" ] || continue
    if ! bash "$qdir/$hook.sh" > "/tmp/selftest-$id-$hook.log" 2>&1; then
      err "$id: $hook fixture 실행 실패 (/tmp/selftest-$id-$hook.log)"
      FAIL=$((FAIL+1)); FAILED_IDS+=("$id:$hook-run")
    else
      question_runtime_grade "$id" "$qdir" > "/tmp/selftest-$id-$hook-grade.log" 2>&1 || true
      read -r hs he hm <<< "$(parse_result "$(state_get "$id")")"
      if [ "$hook" = near-miss-tamper ]; then
        # Anti-tamper fixtures deliberately fail the candidate guard and may
        # therefore earn zero.  They still must remain a valid non-passing
        # grade; ordinary near-miss fixtures must demonstrate partial credit.
        if [ "$hs" != FAIL ] || [ "$he" -lt 0 ] || [ "$he" -ge "$hm" ]; then
          err "$id: tamper near-miss가 유효한 실패 점수가 아님 ($hs $he/$hm)"
          FAIL=$((FAIL+1)); FAILED_IDS+=("$id:near-miss-tamper-contract")
        fi
      elif [[ "$hook" = near-miss* ]]; then
        if [ "$hs" != FAIL ] || [ "$he" -le 0 ] || [ "$he" -ge "$hm" ]; then
          err "$id: near-miss가 엄격한 부분 점수가 아님 ($hs $he/$hm)"
          FAIL=$((FAIL+1)); FAILED_IDS+=("$id:near-miss-contract")
        fi
      elif [ "$hs" != PASS ]; then
        err "$id: alternative 풀이가 만점으로 인정되지 않음 ($hs $he/$hm)"
        FAIL=$((FAIL+1)); FAILED_IDS+=("$id:alternative-contract")
      fi
    fi
    # 각 fixture 뒤 known solve 검증을 오염시키지 않도록 setup을 반복 실행한다.
    if ! question_runtime_reset "$id" "$qdir" > "/tmp/selftest-$id-reset-after-$hook.log" 2>&1; then
      err "$id: $hook 뒤 반복 setup 실패"
      FAIL=$((FAIL+1)); FAILED_IDS+=("$id:repeat-setup")
      break
    fi
  done

  if ! bash "$qdir/solve.sh" > "/tmp/selftest-$id-solve.log" 2>&1; then
    err "$id: solve 실패 (/tmp/selftest-$id-solve.log)"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:solve")
  else
    question_runtime_grade "$id" "$qdir" > "/tmp/selftest-$id-post.log" 2>&1 || true
    read -r s1 e1 m1 <<< "$(parse_result "$(state_get "$id")")"

    if [ "$s1" = PASS ]; then
      if [ "$e0" -eq "$m0" ]; then
        warn "$id: setup 직후에 이미 만점 ($e0/$m0) — 문제 성립 안 함"
        FAIL=$((FAIL+1)); FAILED_IDS+=("$id:trivial")
      else
        ok "$id: pre $e0/$m0 → post $e1/$m1 만점 ✓"
        PASS=$((PASS+1))
      fi
    elif [ "$s1" = INVALID ]; then
      err "$id: solve 후 채점이 INVALID — 랩/채점 인프라 확인 (/tmp/selftest-$id-post.log)"
      FAIL=$((FAIL+1)); FAILED_IDS+=("$id:invalid-post")
    else
      err "$id: solve 후에도 만점 아님 ($e1/$m1) — /tmp/selftest-$id-post.log"
      FAIL=$((FAIL+1)); FAILED_IDS+=("$id:grade")
    fi
  fi

  if ! cleanup_one "$qdir" "$id"; then
    err "$id: teardown/cleanup 실패"
    FAIL=$((FAIL+1)); FAILED_IDS+=("$id:cleanup")
  fi
}

for d in "${DOMAIN_ORDER[@]}"; do
  [ -n "$DOMAIN" ] && [ "$d" != "$DOMAIN" ] && continue
  for qdir in "$CKA_ROOT/questions/$d"/*/; do
    [ -d "$qdir" ] || continue
    [ -n "$ONLY" ] && [ "$(basename "$qdir")" != "$ONLY" ] && continue
    environment="$(question_runtime_environment "$qdir")" || die "문제 환경 metadata 오류: $qdir"
    if question_runtime_is_disposable "$environment" \
        && [ "$INCLUDE_DISPOSABLE" -ne 1 ] && [ -z "$ONLY" ]; then
      printf '%s\n' "${C_YLW}[skip]${C_RST} $(basename "$qdir"): $environment (use --include-disposable)"
      SKIP=$((SKIP+1))
      continue
    fi
    run_one "$qdir"
  done
done

printf '\n%s\n' "${C_BLD}══ selftest 결과: 통과 $PASS / 실패 $FAIL / 건너뜀 $SKIP ══${C_RST}"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "실패 목록: ${FAILED_IDS[*]}"
  exit 1
fi
