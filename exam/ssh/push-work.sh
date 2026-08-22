#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run_id=""
source_root=""
questions_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || ssh_exam_die '--run-id needs a value'; run_id="$2"; shift 2 ;;
    --source-root) [ "$#" -ge 2 ] || ssh_exam_die '--source-root needs a value'; source_root="$2"; shift 2 ;;
    --questions-file) [ "$#" -ge 2 ] || ssh_exam_die '--questions-file needs a value'; questions_file="$2"; shift 2 ;;
    *) ssh_exam_die "unknown argument: $1" ;;
  esac
done

ssh_exam_validate_run_id "$run_id"
ssh_exam_require_docker
ssh_exam_require_safe_work_root "$source_root"
[ -r "$questions_file" ] || ssh_exam_die "questions file is not readable: $questions_file"

prefix="$(ssh_exam_prefix "$run_id")"
target_container="${prefix}-target"
target_id="$(ssh_exam_owned_container_id "$target_container" "$run_id")"
[ "$(docker container inspect --format '{{.State.Running}}' "$target_id")" = true ] \
  || ssh_exam_die 'target must be running while inputs are copied'

docker exec --user root "$target_id" sh -ceu '
  install -d -o candidate -g candidate -m 0755 /home/candidate/cka
'

while IFS= read -r question_id; do
  question_id="${question_id%$'\r'}"
  ssh_exam_validate_question_id "$question_id"
  source_path="$source_root/$question_id"
  docker exec --user root "$target_id" install -d -o candidate -g candidate -m 0755 \
    "/home/candidate/cka/$question_id"
  if [ -d "$source_path" ]; then
    [ ! -L "$source_path" ] || ssh_exam_die "work input is a symlink: $source_path"
    ssh_exam_validate_input_tree "$source_path"
    docker cp "$source_path/." "$target_id:/home/candidate/cka/$question_id"
    docker exec --user root "$target_id" chown -R candidate:candidate \
      "/home/candidate/cka/$question_id"
  elif [ -e "$source_path" ] || [ -L "$source_path" ]; then
    ssh_exam_die "work input is not a directory: $source_path"
  fi
done < "$questions_file"
