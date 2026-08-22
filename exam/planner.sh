#!/usr/bin/env bash
# Deterministic, compatibility-aware mock-exam form planner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKA_ROOT="${CKA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CATALOG="${CKA_FORM_CATALOG:-$SCRIPT_DIR/forms/question-catalog.tsv}"

declare -A Q_DOMAIN Q_PRIORITY Q_MUTEX Q_BREAKS Q_REQUIRES Q_ENABLED Q_SEEN
CATALOG_IDS=()
SELECTED=()
FORM_ATTEMPT=""
RANK_VALUE=0

usage() {
  cat <<'EOF'
Usage:
  exam/planner.sh --seed <seed> [--questions-out <file>] [--setup-order-out <file>]
  exam/planner.sh --validate <questions-file>

The same catalog and seed always produce the same compatible 17-question form.
EOF
}

fail() { printf 'planner: %s\n' "$*" >&2; exit 1; }

trim_cr() { printf '%s' "${1%$'\r'}"; }

load_catalog() {
  [ -r "$CATALOG" ] || fail "catalog not readable: $CATALOG"
  local id domain priority mutex breaks requires enabled extra meta_domain meta_environment meta_key meta_value
  while IFS='|' read -r id domain priority mutex breaks requires enabled extra; do
    id="$(trim_cr "$id")"
    enabled="$(trim_cr "${enabled:-}")"
    [ -n "$id" ] || continue
    case "$id" in \#*) continue ;; esac
    [ -z "${extra:-}" ] || fail "too many columns for $id"
    [[ "$id" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]] || fail "invalid question id: $id"
    [ -z "${Q_SEEN[$id]:-}" ] || fail "duplicate catalog id: $id"
    case "$domain" in
      storage|workloads-scheduling|services-networking|cluster-architecture|troubleshooting) ;;
      *) fail "invalid domain for $id: $domain" ;;
    esac
    [[ "$priority" =~ ^[0-9]+$ ]] || fail "invalid setup priority for $id: $priority"
    case "$enabled" in true|false) ;; *) fail "enabled must be true/false for $id" ;; esac

    local qdir="$CKA_ROOT/questions/$domain/$id"
    if [ -d "$qdir" ]; then
      for required_file in meta.yaml question.md setup.sh grade.sh; do
        [ -f "$qdir/$required_file" ] || fail "$id is missing $required_file"
      done
      meta_domain=""
      meta_environment="shared-kind"
      while IFS=':' read -r meta_key meta_value; do
        meta_value="${meta_value%$'\r'}"
        meta_value="${meta_value#"${meta_value%%[![:space:]]*}"}"
        case "$meta_key" in
          domain) meta_domain="$meta_value" ;;
          environment) meta_environment="$meta_value" ;;
        esac
      done < "$qdir/meta.yaml"
      [ "$meta_domain" = "$domain" ] || fail "$id catalog/meta domain mismatch: $domain != $meta_domain"
      if [ "$enabled" = true ] && [ "$meta_environment" != shared-kind ]; then
        fail "$id is enabled for the shared mock but requires environment: $meta_environment"
      fi
    elif [ "$enabled" = true ]; then
      fail "enabled question directory missing for $id: $qdir"
    fi

    Q_SEEN[$id]=1
    Q_DOMAIN[$id]="$domain"
    Q_PRIORITY[$id]="$priority"
    Q_MUTEX[$id]="$mutex"
    Q_BREAKS[$id]="$breaks"
    Q_REQUIRES[$id]="$requires"
    Q_ENABLED[$id]="$enabled"
    CATALOG_IDS+=("$id")
  done < "$CATALOG"

  local found qid
  for domain in storage workloads-scheduling services-networking cluster-architecture troubleshooting; do
    for qdir in "$CKA_ROOT/questions/$domain"/*/; do
      [ -d "$qdir" ] || continue
      qid="${qdir%/}"
      qid="${qid##*/}"
      [ -n "${Q_SEEN[$qid]:-}" ] || fail "question missing from catalog: $qid"
    done
  done
}

csv_intersects() {
  local left="$1" right="$2" token
  [ -n "$left" ] && [ -n "$right" ] || return 1
  local old_ifs="$IFS"
  IFS=','
  for token in $left; do
    case ",$right," in *",$token,"*) IFS="$old_ifs"; return 0 ;; esac
  done
  IFS="$old_ifs"
  return 1
}

questions_conflict() {
  local a="$1" b="$2"
  csv_intersects "${Q_MUTEX[$a]}" "${Q_MUTEX[$b]}" && return 0
  csv_intersects "${Q_BREAKS[$a]}" "${Q_BREAKS[$b]}" && return 0
  csv_intersects "${Q_BREAKS[$a]}" "${Q_REQUIRES[$b]}" && return 0
  csv_intersects "${Q_REQUIRES[$a]}" "${Q_BREAKS[$b]}" && return 0
  return 1
}

compatible_with_selected() {
  local candidate="$1" chosen
  for chosen in "${SELECTED[@]:-}"; do
    [ -n "$chosen" ] || continue
    questions_conflict "$candidate" "$chosen" && return 1
  done
  return 0
}

rank_for() {
  # FNV-1a-style 32-bit hash implemented with Bash builtins. Avoiding one
  # cksum/awk process per question matters on Windows/WSL launch paths.
  local input="$1|$2|$3" hash=2166136261 i code
  local LC_ALL=C
  for ((i=0; i<${#input}; i++)); do
    printf -v code '%d' "'${input:i:1}"
    hash=$(( ((hash ^ code) * 16777619) & 0xffffffff ))
  done
  RANK_VALUE="$hash"
}

ranked_candidates() {
  local seed="$1" phase="$2" domain="$3" id
  for id in "${CATALOG_IDS[@]}"; do
    [ "${Q_ENABLED[$id]}" = true ] || continue
    [ "${Q_DOMAIN[$id]}" = "$domain" ] || continue
    rank_for "$seed" "$phase" "$id"
    printf '%s\t%s\n' "$RANK_VALUE" "$id"
  done | LC_ALL=C sort -n -k1,1 -k2,2 | cut -f2
}

select_domain() {
  local seed="$1" attempt="$2" domain="$3" wanted="$4" id count=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if compatible_with_selected "$id"; then
      SELECTED+=("$id")
      count=$((count + 1))
      [ "$count" -eq "$wanted" ] && return 0
    fi
  done < <(ranked_candidates "$seed" "select:$attempt:$domain" "$domain")
  return 1
}

generate_form() {
  local seed="$1" attempt
  # Starting with troubleshooting makes its infrastructure-breaking scenarios
  # constrain later domains instead of being silently omitted by domain order.
  for attempt in $(seq 0 999); do
    SELECTED=()
    select_domain "$seed" "$attempt" troubleshooting 5 || continue
    select_domain "$seed" "$attempt" cluster-architecture 4 || continue
    select_domain "$seed" "$attempt" services-networking 3 || continue
    select_domain "$seed" "$attempt" workloads-scheduling 3 || continue
    select_domain "$seed" "$attempt" storage 2 || continue
    [ "${#SELECTED[@]}" -eq 17 ] || continue
    FORM_ATTEMPT="$attempt"
    return 0
  done
  return 1
}

validate_form() {
  local file="$1" id other count=0
  [ -r "$file" ] || fail "form not readable: $file"
  declare -A seen counts
  counts[troubleshooting]=0
  counts[cluster-architecture]=0
  counts[services-networking]=0
  counts[workloads-scheduling]=0
  counts[storage]=0
  local ids=()
  while IFS= read -r id; do
    id="$(trim_cr "$id")"
    [ -n "$id" ] || continue
    [ -n "${Q_SEEN[$id]:-}" ] || fail "form contains unknown question: $id"
    [ "${Q_ENABLED[$id]}" = true ] || fail "form contains disabled question: $id"
    [ -z "${seen[$id]:-}" ] || fail "form contains duplicate question: $id"
    for other in "${ids[@]:-}"; do
      [ -n "$other" ] || continue
      questions_conflict "$id" "$other" && fail "incompatible questions: $other and $id"
    done
    seen[$id]=1
    ids+=("$id")
    counts[${Q_DOMAIN[$id]}]=$(( counts[${Q_DOMAIN[$id]}] + 1 ))
    count=$((count + 1))
  done < "$file"
  [ "$count" -eq 17 ] || fail "form must contain 17 questions, got $count"
  [ "${counts[troubleshooting]}" -eq 5 ] || fail "form must contain 5 troubleshooting questions"
  [ "${counts[cluster-architecture]}" -eq 4 ] || fail "form must contain 4 cluster-architecture questions"
  [ "${counts[services-networking]}" -eq 3 ] || fail "form must contain 3 services-networking questions"
  [ "${counts[workloads-scheduling]}" -eq 3 ] || fail "form must contain 3 workloads-scheduling questions"
  [ "${counts[storage]}" -eq 2 ] || fail "form must contain 2 storage questions"
}

write_generated_form() {
  local seed="$1" questions_out="$2" setup_out="$3" attempt tmp
  generate_form "$seed" || fail "could not build a compatible form for seed: $seed"
  attempt="$FORM_ATTEMPT"
  tmp="$(mktemp)"

  local id
  for id in "${SELECTED[@]}"; do
    rank_for "$seed" "display:$attempt" "$id"
    printf '%s\t%s\n' "$RANK_VALUE" "$id"
  done | LC_ALL=C sort -n -k1,1 -k2,2 | cut -f2 > "$tmp"
  validate_form "$tmp"

  if [ "$questions_out" = - ]; then
    cat "$tmp"
  else
    cp "$tmp" "$questions_out"
  fi

  if [ -n "$setup_out" ]; then
    while IFS= read -r id; do
      rank_for "$seed" "setup:$attempt" "$id"
      printf '%09d\t%s\t%s\n' "${Q_PRIORITY[$id]}" \
        "$RANK_VALUE" "$id"
    done < "$tmp" | LC_ALL=C sort -n -k1,1 -k2,2 -k3,3 | cut -f3 > "$setup_out"
  fi
  rm -f "$tmp"
}

main() {
  local seed="" questions_out=- setup_out="" validate_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --seed) [ "$#" -ge 2 ] || fail "--seed requires a value"; seed="$2"; shift 2 ;;
      --questions-out) [ "$#" -ge 2 ] || fail "--questions-out requires a file"; questions_out="$2"; shift 2 ;;
      --setup-order-out) [ "$#" -ge 2 ] || fail "--setup-order-out requires a file"; setup_out="$2"; shift 2 ;;
      --validate) [ "$#" -ge 2 ] || fail "--validate requires a file"; validate_file="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  load_catalog
  if [ -n "$validate_file" ]; then
    validate_form "$validate_file"
    return 0
  fi
  [ -n "$seed" ] || fail "--seed is required"
  [[ "$seed" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || fail "seed contains unsupported characters"
  [ "$questions_out" = - ] || mkdir -p "$(dirname "$questions_out")"
  [ -z "$setup_out" ] || mkdir -p "$(dirname "$setup_out")"
  write_generated_form "$seed" "$questions_out" "$setup_out"
}

if [ "${CKA_PLANNER_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
