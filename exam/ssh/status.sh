#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

run_id="${1:-}"
ssh_exam_validate_run_id "$run_id"
ssh_exam_require_docker
prefix="$(ssh_exam_prefix "$run_id")"

for role in base target; do
  container="${prefix}-${role}"
  if ssh_exam_container_exists "$container"; then
    ssh_exam_require_owned_container "$container" "$run_id"
    docker container inspect --format \
      "${role}: status={{.State.Status}} running={{.State.Running}}" "$container"
  else
    printf '%s: absent\n' "$role"
  fi
done

network="${prefix}-net"
if ssh_exam_network_exists "$network"; then
  ssh_exam_require_owned_network "$network" "$run_id"
  printf 'network: present\n'
else
  printf 'network: absent\n'
fi
