#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/supported-questions.txt"
ANSWER_FILES="$SCRIPT_DIR/answer-files.tsv"
SOURCE_CATALOG="$REPO_ROOT/exam/forms/question-catalog.tsv"

usage() {
  cat <<'EOF'
usage:
  gated-form.sh --catalog-out PATH
  gated-form.sh --verify-form PATH
EOF
}

fail() { printf 'ssh gated form: %s\n' "$*" >&2; exit 1; }

validate_contract() {
  local id domain count environment qdir
  declare -A allowed=() seen_catalog=() answer_ids=()
  declare -A quota=(
    [troubleshooting]=5
    [cluster-architecture]=4
    [services-networking]=3
    [workloads-scheduling]=3
    [storage]=2
  )
  declare -A available=(
    [troubleshooting]=0
    [cluster-architecture]=0
    [services-networking]=0
    [workloads-scheduling]=0
    [storage]=0
  )

  while IFS= read -r id; do
    case "$id" in ''|\#*) continue ;; esac
    ssh_exam_validate_question_id "$id"
    [ -z "${allowed[$id]+x}" ] || fail "duplicate allowlist ID: $id"
    allowed[$id]=1
  done < "$ALLOWLIST"

  while IFS='|' read -r id domain _priority _mutex _breaks _requires enabled extra; do
    id="${id%$'\r'}"; enabled="${enabled%$'\r'}"
    case "$id" in ''|\#*) continue ;; esac
    [ -z "${extra:-}" ] || fail "catalog has extra fields for $id"
    seen_catalog[$id]="$enabled"
    if [ -n "${allowed[$id]+x}" ]; then
      [ "$enabled" = true ] || fail "allowlisted question is disabled in the main catalog: $id"
      qdir="$REPO_ROOT/questions/$domain/$id"
      [ -d "$qdir" ] || fail "question directory missing: $id"
      environment="$(awk -F':' '
        $1 == "environment" {
          value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit
        }
      ' "$qdir/meta.yaml")"
      [ -n "$environment" ] || environment=shared-kind
      [ "$environment" = shared-kind ] \
        || fail "allowlisted question is not shared-kind: $id ($environment)"
      available[$domain]=$(( ${available[$domain]:-0} + 1 ))
    fi
  done < "$SOURCE_CATALOG"

  for id in "${!allowed[@]}"; do
    [ -n "${seen_catalog[$id]+x}" ] || fail "allowlisted question is missing from catalog: $id"
  done
  for domain in "${!quota[@]}"; do
    count="${available[$domain]:-0}"
    [ "$count" -ge "${quota[$domain]}" ] \
      || fail "$domain has $count supported questions; ${quota[$domain]} required"
  done

  while IFS='|' read -r id relative extra; do
    id="${id%$'\r'}"; relative="${relative%$'\r'}"
    case "$id" in ''|\#*) continue ;; esac
    [ -z "${extra:-}" ] || fail "answer manifest has extra fields for $id"
    [ -n "${allowed[$id]+x}" ] || fail "answer manifest references unsupported question: $id"
    case "$relative" in
      ''|/*|*..*|*/*|*[!A-Za-z0-9._-]*) fail "unsafe answer path for $id: $relative" ;;
    esac
    [ -z "${answer_ids[$id|$relative]+x}" ] || fail "duplicate answer file: $id/$relative"
    answer_ids[$id|$relative]=1
  done < "$ANSWER_FILES"

  # The host grader, question metadata, and immutable collection allowlist
  # must describe exactly the same files.  A stale TSV must fail before form
  # generation rather than silently turning a correct answer into zero points.
  python3 - "$REPO_ROOT" "$ALLOWLIST" "$ANSWER_FILES" "$SOURCE_CATALOG" <<'PY' \
    || fail 'answer file contract mismatch (grader/meta/TSV must be exact)'
import json, pathlib, re, sys

root=pathlib.Path(sys.argv[1])
allowed={line.strip() for line in open(sys.argv[2],encoding="utf-8") if line.strip() and not line.startswith("#")}
manifest={qid:set() for qid in allowed}
for raw in open(sys.argv[3],encoding="utf-8"):
    raw=raw.rstrip("\r\n")
    if not raw or raw.startswith("#"): continue
    qid,name=raw.split("|")
    manifest.setdefault(qid,set()).add(name)
domains={}
for raw in open(sys.argv[4],encoding="utf-8"):
    raw=raw.rstrip("\r\n")
    if not raw or raw.startswith("#"): continue
    fields=raw.split("|")
    domains[fields[0]]=fields[1]

def answer_files(meta_text):
    lines=meta_text.splitlines(); result=[]
    for index,line in enumerate(lines):
        inline=re.fullmatch(r"answer_files:\s*(\[.*\])\s*",line)
        if inline:
            value=json.loads(inline.group(1))
            if not isinstance(value,list) or any(not isinstance(item,str) for item in value):
                raise SystemExit("invalid inline answer_files metadata")
            return set(value)
        if line.rstrip()=="answer_files:":
            for child in lines[index+1:]:
                match=re.fullmatch(r"\s+-\s+([A-Za-z0-9._-]+)\s*",child)
                if match: result.append(match.group(1)); continue
                if child.strip() and not child.startswith((" ","\t")): break
            break
    return set(result)

failed=[]
for qid in sorted(allowed):
    qdir=root/"questions"/domains[qid]/qid
    declared=answer_files((qdir/"meta.yaml").read_text(encoding="utf-8"))
    grade=(qdir/"grade.sh").read_text(encoding="utf-8")
    referenced=set(re.findall(r"(?:\\)?\$CKA_WORK_DIR/"+re.escape(qid)+r"/([A-Za-z0-9._-]+)",grade))
    if declared != manifest.get(qid,set()) or referenced != declared:
        failed.append(f"{qid}: grader={sorted(referenced)} meta={sorted(declared)} manifest={sorted(manifest.get(qid,set()))}")
if failed:
    print("\n".join(failed),file=sys.stderr)
    raise SystemExit(1)
PY

  # Candidate-visible instructions for the gated set must not require a node
  # shell or a tool absent from the designated target. Host-only setup/grading
  # scripts may still use Docker to construct and inspect the lab.
  for id in "${!allowed[@]}"; do
    domain=""
    while IFS='|' read -r catalog_id catalog_domain _; do
      [ "$catalog_id" = "$id" ] || continue
      domain="$catalog_domain"
      break
    done < "$SOURCE_CATALOG"
    [ -n "$domain" ] || fail "cannot resolve domain for $id"
    if grep -Eqi 'ssh[[:space:]]+cka-|\b(etcdctl|etcdutl|kubeadm|helm|systemctl|journalctl)\b|/etc/kubernetes|https?://(localhost|127\.0\.0\.1)' \
        "$REPO_ROOT/questions/$domain/$id/question.md"; then
      fail "$id requires a node shell or an unavailable target tool"
    fi
    if grep -q 'CKA_WORK_DIR' "$REPO_ROOT/questions/$domain/$id/grade.sh" \
        && ! grep -q "^${id}|" "$ANSWER_FILES"; then
      fail "$id grader reads host work files but has no answer-file manifest"
    fi
  done
}

catalog_out=""
verify_form=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog-out) [ "$#" -ge 2 ] || fail '--catalog-out needs a path'; catalog_out="$2"; shift 2 ;;
    --verify-form) [ "$#" -ge 2 ] || fail '--verify-form needs a path'; verify_form="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
[ -n "$catalog_out" ] || [ -n "$verify_form" ] || { usage >&2; exit 1; }
[ -z "$catalog_out" ] || [ -z "$verify_form" ] || fail 'choose one operation'

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
validate_contract

if [ -n "$catalog_out" ]; then
  [ "$catalog_out" != "$SOURCE_CATALOG" ] || fail 'refusing to overwrite the main catalog'
  mkdir -p "$(dirname "$catalog_out")"
  tmp="$catalog_out.tmp.$$"
  awk -F'|' -v OFS='|' '
    NR == FNR {
      sub(/\r$/, "", $0)
      if ($0 != "" && $0 !~ /^#/) allow[$0] = 1
      next
    }
    /^#/ || NF == 0 { print; next }
    {
      sub(/\r$/, "", $7)
      $7 = (($1 in allow) && $7 == "true") ? "true" : "false"
      # In the SSH form ca-01 is deterministically prepared before ca-02.
      # ca-02 preserves an existing dev-team namespace, so the two API-only
      # exercises safely coexist once the destructive order is removed.
      if ($1 == "ca-01") { $3 = 90; $4 = "" }
      if ($1 == "ca-02") { $3 = 100; $4 = "" }
      print
    }
  ' "$ALLOWLIST" "$SOURCE_CATALOG" > "$tmp"
  mv -f "$tmp" "$catalog_out"
  printf '%s\n' "$catalog_out"
  exit 0
fi

[ -r "$verify_form" ] || fail "form is not readable: $verify_form"
declare -A allowed=()
while IFS= read -r id; do
  case "$id" in ''|\#*) continue ;; esac
  allowed[$id]=1
done < "$ALLOWLIST"
count=0
declare -A selected=()
while IFS= read -r id; do
  id="${id%$'\r'}"
  ssh_exam_validate_question_id "$id"
  [ -n "${allowed[$id]+x}" ] || fail "form contains unsupported question: $id"
  [ -z "${selected[$id]+x}" ] || fail "form contains duplicate question: $id"
  selected[$id]=1
  count=$((count + 1))
done < "$verify_form"
[ "$count" -eq 17 ] || fail "form contains $count questions, expected 17"
printf 'verified 17-question SSH gated form\n'
