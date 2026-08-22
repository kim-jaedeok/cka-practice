#!/usr/bin/env bash

SSH_EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_REPO_ROOT="$(cd "$SSH_EXAM_DIR/../.." && pwd)"

ssh_exam_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ssh_exam_require_docker() {
  command -v docker >/dev/null 2>&1 || ssh_exam_die 'docker is required'
  docker info >/dev/null 2>&1 || ssh_exam_die 'docker daemon is not reachable'
}

ssh_exam_validate_run_id() {
  case "${1:-}" in
    ''|*[!a-z0-9-]*|-*|*-) ssh_exam_die 'run id must match [a-z0-9][a-z0-9-]*' ;;
  esac
  [ "${#1}" -le 32 ] || ssh_exam_die 'run id must be at most 32 characters'
}

ssh_exam_validate_question_id() {
  case "${1:-}" in
    ''|*[!a-z0-9-]*|-*|*-) ssh_exam_die 'question id must match [a-z0-9][a-z0-9-]*' ;;
  esac
  [ "${#1}" -le 63 ] || ssh_exam_die 'question id must be at most 63 characters'
}

ssh_exam_require_safe_work_root() {
  local root="$1" resolved
  case "$root" in /*) ;; *) ssh_exam_die "work root must be absolute: $root" ;; esac
  [ "$root" != / ] || ssh_exam_die 'work root cannot be /'
  [ -d "$root" ] && [ ! -L "$root" ] \
    || ssh_exam_die "work root must be a real directory: $root"
  resolved="$(realpath -e -- "$root")" \
    || ssh_exam_die "cannot resolve work root: $root"
  [ "$resolved" = "$root" ] \
    || ssh_exam_die "work root must be canonical and contain no symlink components: $root"
}

ssh_exam_validate_answer_path() {
  case "${1:-}" in
    ''|/*|*..*|*/*|*[!A-Za-z0-9._-]*) ssh_exam_die "unsafe answer path: ${1:-}" ;;
  esac
}

ssh_exam_validate_input_tree() {
  local root="$1"
  python3 - "$root" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
max_files = 2000
max_total = 32 * 1024 * 1024
max_file = 8 * 1024 * 1024
files = 0
total = 0

for current, directories, names in os.walk(root, topdown=True, followlinks=False):
    for name in directories + names:
        path = os.path.join(current, name)
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f"work input contains a symlink: {path}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"work input contains a special file: {path}")
        if metadata.st_nlink != 1:
            raise SystemExit(f"work input contains a hard link: {path}")
        if metadata.st_size > max_file:
            raise SystemExit(f"work input file exceeds {max_file} bytes: {path}")
        files += 1
        total += metadata.st_size
        if files > max_files or total > max_total:
            raise SystemExit("work input tree exceeds its bounded copy contract")
PY
}

ssh_exam_prefix() {
  printf 'cka-ssh-%s' "$1"
}

ssh_exam_container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

ssh_exam_network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

ssh_exam_require_owned_container() {
  ssh_exam_owned_container_id "$1" "$2" >/dev/null
}

ssh_exam_require_owned_network() {
  ssh_exam_owned_network_id "$1" "$2" >/dev/null
}

ssh_exam_owned_container_id() {
  local container="$1" run_id="$2" record object_id actual
  record="$(docker container inspect --format \
    '{{.Id}} {{index .Config.Labels "org.cka-practice.ssh-run"}}' "$container")" \
    || ssh_exam_die "container not found: $container"
  object_id="${record%% *}"
  actual="${record#* }"
  [ "$actual" = "$run_id" ] || ssh_exam_die "refusing unowned container: $container"
  case "$object_id" in
    ''|*[!0-9a-f]*) ssh_exam_die "invalid container id for $container" ;;
  esac
  printf '%s\n' "$object_id"
}

# Resolve lifecycle objects by immutable labels instead of their mutable Docker
# names. Docker permits a running container to be renamed, so seal/cleanup must
# enumerate every object owned by the run and operate on the inspected IDs.
ssh_exam_owned_container_ids_by_role() {
  local run_id="$1" role="$2" ids id record inspected_id actual_run actual_role extra
  case "$role" in base|target) ;; *) ssh_exam_die "invalid SSH container role: $role" ;; esac
  ids="$(docker container ls --all --quiet --no-trunc \
    --filter "label=org.cka-practice.ssh-run=$run_id" \
    --filter "label=org.cka-practice.ssh-role=$role")" \
    || ssh_exam_die 'cannot enumerate SSH exam containers'
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    record="$(docker container inspect --format \
      '{{.Id}} {{index .Config.Labels "org.cka-practice.ssh-run"}} {{index .Config.Labels "org.cka-practice.ssh-role"}}' \
      "$id")" || ssh_exam_die "container disappeared during ownership check: $id"
    IFS=' ' read -r inspected_id actual_run actual_role extra <<< "$record"
    [ "$inspected_id" = "$id" ] && [ "$actual_run" = "$run_id" ] \
      && [ "$actual_role" = "$role" ] && [ -z "${extra:-}" ] \
      || ssh_exam_die "container ownership changed during inspection: $id"
    case "$inspected_id" in
      ''|*[!0-9a-f]*) ssh_exam_die "invalid container id: $inspected_id" ;;
    esac
    printf '%s\n' "$inspected_id"
  done <<< "$ids"
}

ssh_exam_owned_network_id() {
  local network="$1" run_id="$2" record object_id actual
  record="$(docker network inspect --format \
    '{{.Id}} {{index .Labels "org.cka-practice.ssh-run"}}' "$network")" \
    || ssh_exam_die "network not found: $network"
  object_id="${record%% *}"
  actual="${record#* }"
  [ "$actual" = "$run_id" ] || ssh_exam_die "refusing unowned network: $network"
  case "$object_id" in
    ''|*[!0-9a-f]*) ssh_exam_die "invalid network id for $network" ;;
  esac
  printf '%s\n' "$object_id"
}

ssh_exam_owned_network_ids() {
  local run_id="$1" ids id record inspected_id actual_run actual_purpose extra
  ids="$(docker network ls --quiet --no-trunc \
    --filter "label=org.cka-practice.ssh-run=$run_id" \
    --filter 'label=org.cka-practice.ssh-purpose=designated-host')" \
    || ssh_exam_die 'cannot enumerate SSH exam networks'
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    record="$(docker network inspect --format \
      '{{.Id}} {{index .Labels "org.cka-practice.ssh-run"}} {{index .Labels "org.cka-practice.ssh-purpose"}}' \
      "$id")" || ssh_exam_die "network disappeared during ownership check: $id"
    IFS=' ' read -r inspected_id actual_run actual_purpose extra <<< "$record"
    [ "$inspected_id" = "$id" ] && [ "$actual_run" = "$run_id" ] \
      && [ "$actual_purpose" = designated-host ] && [ -z "${extra:-}" ] \
      || ssh_exam_die "network ownership changed during inspection: $id"
    case "$inspected_id" in
      ''|*[!0-9a-f]*) ssh_exam_die "invalid network id: $inspected_id" ;;
    esac
    printf '%s\n' "$inspected_id"
  done <<< "$ids"
}

ssh_exam_require_image_role() {
  local image="$1" expected="$2" actual
  actual="$(docker image inspect \
    --format '{{index .Config.Labels "org.cka-practice.ssh-image-role"}}' "$image" 2>/dev/null)" \
    || ssh_exam_die "image not found: $image"
  [ "$actual" = "$expected" ] \
    || ssh_exam_die "image $image is not the expected $expected image"
}

ssh_exam_require_image_label() {
  local image="$1" key="$2" expected="$3" actual
  actual="$(docker image inspect \
    --format "{{index .Config.Labels \"$key\"}}" "$image" 2>/dev/null)" \
    || ssh_exam_die "image not found: $image"
  [ "$actual" = "$expected" ] \
    || ssh_exam_die "image $image label $key must be $expected (found: $actual)"
}
