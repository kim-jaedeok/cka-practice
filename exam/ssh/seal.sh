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
target_output="$(ssh_exam_owned_container_ids_by_role "$run_id" target)"
target_ids=()
[ -z "$target_output" ] || mapfile -t target_ids <<< "$target_output"

# Stop the designated host itself first.  This terminates SSH children and any
# candidate background process, including processes still using cluster network.
for target_id in "${target_ids[@]}"; do
  if [ "$(docker container inspect --format '{{.State.Running}}' "$target_id")" = true ]; then
    docker container stop --time 0 "$target_id" >/dev/null
  fi
done

base_output="$(ssh_exam_owned_container_ids_by_role "$run_id" base)"
base_ids=()
[ -z "$base_output" ] || mapfile -t base_ids <<< "$base_output"
for base_id in "${base_ids[@]}"; do
  if [ "$(docker container inspect --format '{{.State.Running}}' "$base_id")" = true ]; then
    docker container stop --time 0 "$base_id" >/dev/null
  fi
done

network_output="$(ssh_exam_owned_network_ids "$run_id")"
network_ids=()
[ -z "$network_output" ] || mapfile -t network_ids <<< "$network_output"
for network_id in "${network_ids[@]}"; do
  for target_id in "${target_ids[@]}"; do
    if docker network inspect --format '{{range $id, $_ := .Containers}}{{println $id}}{{end}}' "$network_id" \
       | grep -Fx "$target_id" >/dev/null; then
      docker network disconnect --force "$network_id" "$target_id"
    fi
  done
done

printf 'sealed run %s: target and base stopped; target filesystem preserved for grading\n' "$run_id"
