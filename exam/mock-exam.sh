#!/usr/bin/env bash
# 모의고사 모드: 도메인 비중대로 17문제 샘플링, 2시간 타이머, 일괄 채점 성적표
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

EXAM_DIR="$CKA_STATE_DIR/exam"
RESULT_DIR="$CKA_STATE_DIR/exam-results"
DURATION_MIN=120
PASS_PCT=66

# 실제 시험 도메인 비중 반영 샘플링 (합계 17)
#   troubleshooting 30% → 5, cluster-architecture 25% → 4,
#   services-networking 20% → 3, workloads-scheduling 15% → 3, storage 10% → 2
sample_questions() {
  {
    ls "$CKA_ROOT/questions/troubleshooting"      | shuf | head -5
    ls "$CKA_ROOT/questions/cluster-architecture" | shuf | head -4
    ls "$CKA_ROOT/questions/services-networking"  | shuf | head -3
    ls "$CKA_ROOT/questions/workloads-scheduling" | shuf | head -3
    ls "$CKA_ROOT/questions/storage"              | shuf | head -2
  } | shuf
}

exam_running() { [ -f "$EXAM_DIR/started" ]; }

qid_of_num() { # q7 또는 7 → 문제 id
  local n="${1#q}"
  sed -n "${n}p" "$EXAM_DIR/questions" 2>/dev/null
}

remaining_seconds() {
  local start now
  start="$(cat "$EXAM_DIR/started")"
  now="$(date +%s)"
  echo $(( DURATION_MIN * 60 - (now - start) ))
}

fmt_mmss() {
  local s=$1
  [ "$s" -lt 0 ] && { printf -- '-'; s=$((-s)); }
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

cmd_start() {
  exam_running && die "이미 진행 중인 모의고사가 있습니다. 'cka exam status' / 'cka exam finish' / 'cka exam abort'"
  require_cluster
  rm -rf "$EXAM_DIR"; mkdir -p "$EXAM_DIR"
  sample_questions > "$EXAM_DIR/questions"

  printf '\n%s\n' "${C_BLD}모의고사 환경을 구성합니다 (17문제, 몇 분 걸립니다)...${C_RST}"
  local i=0 id
  while read -r id; do
    i=$((i+1))
    printf '  [%2d/17] %s 환경 구성 중...\n' "$i" "$id"
    local qdir; qdir="$(qdir_of "$id")"
    bash "$qdir/setup.sh" >/dev/null 2>&1 || warn "$id setup 실패 — 'cka reset $id'로 재시도 가능"
    state_clear "$id"
  done < "$EXAM_DIR/questions"

  date +%s > "$EXAM_DIR/started"
  printf '\n%s\n\n' "${C_GRN}${C_BLD}══ 모의고사 시작! 제한시간 ${DURATION_MIN}분 ══${C_RST}"
  cmd_status
  cat <<EOF
사용법:
  cka exam question <n>   n번 문제 지문 보기 (예: cka exam question 3)
  cka exam status         남은 시간·문제 목록
  cka exam finish         종료 및 채점 (시간 내 언제든 가능)

실전처럼 풀어보세요. 문제 순서는 무작위이며 배점이 높은 문제부터 훑어보는 것도 전략입니다.
EOF
}

cmd_status() {
  exam_running || die "진행 중인 모의고사가 없습니다. 'cka exam' 으로 시작하세요."
  local rem; rem="$(remaining_seconds)"
  if [ "$rem" -lt 0 ]; then
    printf '\n%s\n' "${C_RED}${C_BLD}남은 시간: 00:00:00 — 시간 초과! 'cka exam finish'로 채점하세요.${C_RST}"
  else
    printf '\n%s\n' "${C_BLD}남은 시간: $(fmt_mmss "$rem")${C_RST}"
  fi
  printf '\n%-5s %-8s %-4s %s\n' "NO" "ID" "PTS" "TITLE"
  printf '%s\n' "──────────────────────────────────────────────────"
  local i=0 id qdir
  while read -r id; do
    i=$((i+1))
    qdir="$(qdir_of "$id")"
    printf 'q%-4s %-8s %-4s %s\n' "$i" "$id" "$(meta_get "$qdir" points)" "$(meta_get "$qdir" title)"
  done < "$EXAM_DIR/questions"
  printf '\n'
}

cmd_question() {
  exam_running || die "진행 중인 모의고사가 없습니다."
  local id; id="$(qid_of_num "${1:-}")"
  [ -n "$id" ] || die "문제 번호가 올바르지 않습니다 (q1~q17)."
  local qdir; qdir="$(qdir_of "$id")"
  local n="${1#q}"
  printf '\n%s\n' "${C_BLD}═════ Question ${n}/17 | $(meta_get "$qdir" points) points ═════${C_RST}"
  printf '\n'
  cat "$qdir/question.md"
  printf '\n'
}

cmd_finish() {
  exam_running || die "진행 중인 모의고사가 없습니다."
  local rem overtime=""
  rem="$(remaining_seconds)"
  [ "$rem" -lt 0 ] && overtime="  (시간 초과 종료)"

  printf '\n%s\n' "${C_BLD}채점 중... (문제당 수 초)${C_RST}"

  declare -A DOM_EARNED DOM_MAX
  local total_earned=0 total_max=0 i=0 id qdir dom st e m
  local detail=""
  while read -r id; do
    i=$((i+1))
    qdir="$(qdir_of "$id")"
    dom="$(meta_get "$qdir" domain)"
    bash "$qdir/grade.sh" >/dev/null 2>&1 || true
    st="$(state_get "$id")"           # graded:E/M
    e="${st#graded:}"; m="${e#*/}"; e="${e%%/*}"
    case "$e" in ''|*[!0-9]*) e=0 ;; esac
    case "$m" in ''|*[!0-9]*) m="$(meta_get "$qdir" points)" ;; esac
    total_earned=$((total_earned + e)); total_max=$((total_max + m))
    DOM_EARNED[$dom]=$(( ${DOM_EARNED[$dom]:-0} + e ))
    DOM_MAX[$dom]=$(( ${DOM_MAX[$dom]:-0} + m ))
    detail+="$(printf 'q%-4s %-8s %3s/%-3s %s' "$i" "$id" "$e" "$m" "$(meta_get "$qdir" title)")"$'\n'
  done < "$EXAM_DIR/questions"

  local pct=0
  [ "$total_max" -gt 0 ] && pct=$(( total_earned * 100 / total_max ))

  printf '\n%s\n' "${C_BLD}══════════════ 모의고사 성적표${overtime} ══════════════${C_RST}"
  printf '%s\n' "$detail"
  printf '%s\n' "──────────────────────────────────────────────────"
  printf '%s\n' "${C_BLD}도메인별:${C_RST}"
  local d
  for d in troubleshooting cluster-architecture services-networking workloads-scheduling storage; do
    [ -n "${DOM_MAX[$d]:-}" ] || continue
    local dpct=$(( ${DOM_EARNED[$d]} * 100 / ${DOM_MAX[$d]} ))
    local mark=""
    [ "$dpct" -lt "$PASS_PCT" ] && mark="  ${C_YLW}⚠ 취약${C_RST}"
    printf '  %-24s %3d/%-3d (%d%%)%s\n' "$d" "${DOM_EARNED[$d]}" "${DOM_MAX[$d]}" "$dpct" "$mark"
  done
  printf '%s\n' "──────────────────────────────────────────────────"
  if [ "$pct" -ge "$PASS_PCT" ]; then
    printf '%s\n\n' "${C_GRN}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 합격 (기준 ${PASS_PCT}%)${C_RST}"
  else
    printf '%s\n\n' "${C_RED}${C_BLD}총점: ${total_earned}/${total_max} (${pct}%) → 불합격 (기준 ${PASS_PCT}%)${C_RST}"
  fi
  printf '%s\n\n' "오답 복습: 각 문제의 정답지는 'cka solution <id>' 로 확인하세요."

  # 결과 보관 후 종료 처리
  mkdir -p "$RESULT_DIR"
  {
    printf 'date: %s\nscore: %s/%s (%s%%)%s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$total_earned" "$total_max" "$pct" "$overtime"
    printf '%s\n' "$detail"
  } > "$RESULT_DIR/$(date +%Y%m%d-%H%M%S).txt"

  # 노드 상태를 바꾸는 문제들의 teardown 실행 (환경 정리)
  while read -r id; do
    qdir="$(qdir_of "$id")"
    [ -f "$qdir/teardown.sh" ] && bash "$qdir/teardown.sh" >/dev/null 2>&1 || true
  done < "$EXAM_DIR/questions"

  rm -rf "$EXAM_DIR"
}

cmd_abort() {
  exam_running || die "진행 중인 모의고사가 없습니다."
  local id qdir
  while read -r id; do
    qdir="$(qdir_of "$id")"
    [ -f "$qdir/teardown.sh" ] && bash "$qdir/teardown.sh" >/dev/null 2>&1 || true
  done < "$EXAM_DIR/questions"
  rm -rf "$EXAM_DIR"
  ok "모의고사를 중단했습니다."
}

case "${1:-start}" in
  start)    cmd_start ;;
  status)   cmd_status ;;
  question) cmd_question "${2:-}" ;;
  finish)   cmd_finish ;;
  abort)    cmd_abort ;;
  *) die "사용법: cka exam [status|question <n>|finish|abort]" ;;
esac
