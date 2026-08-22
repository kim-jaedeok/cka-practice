#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run_id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || ssh_exam_die '--run-id needs a value'; run_id="$2"; shift 2 ;;
    -h|--help) printf 'usage: %s --run-id ID\n' "$0"; exit 0 ;;
    *) ssh_exam_die "unknown argument: $1" ;;
  esac
done

ssh_exam_validate_run_id "$run_id"
ssh_exam_require_docker
failed=0

# Stop and remove the designated target before inspecting any secondary
# object. A broken/missing base or network must never leave candidate
# processes running after cleanup was requested.
target_output=""
if target_output="$(ssh_exam_owned_container_ids_by_role "$run_id" target)"; then
  if [ -n "$target_output" ]; then
    while IFS= read -r target_id; do
      [ -n "$target_id" ] || continue
      docker container rm --force "$target_id" >/dev/null || failed=1
    done <<< "$target_output"
  fi
else
  failed=1
fi

base_output=""
if base_output="$(ssh_exam_owned_container_ids_by_role "$run_id" base)"; then
  if [ -n "$base_output" ]; then
    while IFS= read -r base_id; do
      [ -n "$base_id" ] || continue
      docker container rm --force "$base_id" >/dev/null || failed=1
    done <<< "$base_output"
  fi
else
  failed=1
fi

network_output=""
if network_output="$(ssh_exam_owned_network_ids "$run_id")"; then
  if [ -n "$network_output" ]; then
    while IFS= read -r network_id; do
      [ -n "$network_id" ] || continue
      docker network rm "$network_id" >/dev/null || failed=1
    done <<< "$network_output"
  fi
else
  failed=1
fi

# Every removal uses the immutable object ID captured by the same inspect that
# verified its run label. Continue after secondary failures so all safely owned
# objects receive a cleanup attempt.
if [ "$failed" -ne 0 ]; then
  printf 'SSH run %s cleanup was incomplete\n' "$run_id" >&2
  exit 1
fi

printf 'removed ephemeral SSH run %s (not recoverable)\n' "$run_id"
