#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run_id=""
destination_root=""
questions_file=""
stage_root=""
answer_manifest="$SCRIPT_DIR/answer-files.tsv"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || ssh_exam_die '--run-id needs a value'; run_id="$2"; shift 2 ;;
    --destination-root) [ "$#" -ge 2 ] || ssh_exam_die '--destination-root needs a value'; destination_root="$2"; shift 2 ;;
    --questions-file) [ "$#" -ge 2 ] || ssh_exam_die '--questions-file needs a value'; questions_file="$2"; shift 2 ;;
    --stage-root) [ "$#" -ge 2 ] || ssh_exam_die '--stage-root needs a value'; stage_root="$2"; shift 2 ;;
    --answer-manifest) [ "$#" -ge 2 ] || ssh_exam_die '--answer-manifest needs a value'; answer_manifest="$2"; shift 2 ;;
    *) ssh_exam_die "unknown argument: $1" ;;
  esac
done

ssh_exam_validate_run_id "$run_id"
ssh_exam_require_docker
ssh_exam_require_safe_work_root "$destination_root"
[ -r "$questions_file" ] || ssh_exam_die "questions file is not readable: $questions_file"
[ -r "$answer_manifest" ] || ssh_exam_die "answer manifest is not readable: $answer_manifest"
case "$stage_root" in /*) ;; *) ssh_exam_die 'stage root must be absolute' ;; esac
[ ! -e "$stage_root" ] && [ ! -L "$stage_root" ] \
  || ssh_exam_die "stage root already exists: $stage_root"
mkdir -m 0700 "$stage_root"

prefix="$(ssh_exam_prefix "$run_id")"
base_id="$(ssh_exam_owned_container_id "${prefix}-base" "$run_id")"
target_id="$(ssh_exam_owned_container_id "${prefix}-target" "$run_id")"
network_id="$(ssh_exam_owned_network_id "${prefix}-net" "$run_id")"
[ "$(docker container inspect --format '{{.State.Running}}' "$target_id")" = false ] \
  || ssh_exam_die 'refusing to collect before the target is stopped'
[ "$(docker container inspect --format '{{.State.Running}}' "$base_id")" = false ] \
  || ssh_exam_die 'refusing to collect before the base is stopped'
# The ownership check is intentional even though collection does not otherwise
# use the run network.
[ -n "$network_id" ] || ssh_exam_die 'owned run network is missing'

declare -A selected=()
while IFS= read -r question_id; do
  question_id="${question_id%$'\r'}"
  ssh_exam_validate_question_id "$question_id"
  selected[$question_id]=1
done < "$questions_file"

install_answer() {
  local question_id="$1" relative="$2" staged="$3"
  local destination_dir="$destination_root/$question_id"
  local destination="$destination_dir/$relative"
  local temporary="$destination_dir/.cka-ssh-${run_id}-${relative}.tmp"
  [ ! -L "$destination_dir" ] || ssh_exam_die "destination directory is a symlink: $destination_dir"
  mkdir -p "$destination_dir"
  [ ! -L "$destination" ] || ssh_exam_die "destination answer is a symlink: $destination"
  if [ -e "$destination" ] && [ ! -f "$destination" ]; then
    ssh_exam_die "destination answer is not a regular file: $destination"
  fi
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || ssh_exam_die "temporary answer already exists: $temporary"
  if [ -f "$staged" ]; then
    install -m 0600 "$staged" "$temporary"
    mv -f "$temporary" "$destination"
  else
    rm -f -- "$destination"
  fi
}

while IFS='|' read -r question_id relative extra; do
  question_id="${question_id%$'\r'}"; relative="${relative%$'\r'}"
  case "$question_id" in ''|\#*) continue ;; esac
  [ -z "${extra:-}" ] || ssh_exam_die "answer manifest has extra fields for $question_id"
  [ -n "${selected[$question_id]+x}" ] || continue
  ssh_exam_validate_question_id "$question_id"
  ssh_exam_validate_answer_path "$relative"
  mkdir -m 0700 -p "$stage_root/$question_id"
  staged="$stage_root/$question_id/$relative"
  error_log="$stage_root/$question_id/.${relative}.docker-cp.err"

  set +e
  docker cp "$target_id:/home/candidate/cka/$question_id/$relative" - 2> "$error_log" \
    | python3 "$SCRIPT_DIR/extract-answer.py" --name "$relative" --output "$staged"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  copy_rc="${pipeline_status[0]}"
  extract_rc="${pipeline_status[1]}"
  if [ "$copy_rc" -ne 0 ] && [ "$extract_rc" -eq 20 ] && [ ! -e "$staged" ] \
      && grep -Eqi 'could not find the file|no such file or directory' "$error_log"; then
    # A missing candidate answer is a normal wrong answer, not an infrastructure
    # failure. Its host counterpart is removed below so stale setup data cannot
    # receive credit.
    :
  elif [ "$copy_rc" -ne 0 ] || [ "$extract_rc" -ne 0 ]; then
    ssh_exam_die "unsafe or unreadable answer: $question_id/$relative (copy=$copy_rc extract=$extract_rc)"
  fi
  install_answer "$question_id" "$relative" "$staged"
done < "$answer_manifest"

printf 'collected allowlisted answer files for run %s\n' "$run_id"
