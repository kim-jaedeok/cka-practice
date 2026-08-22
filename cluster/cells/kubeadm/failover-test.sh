#!/usr/bin/env bash
# Active HA acceptance contract.  Unlike question graders, this intentionally
# stops cp1 and performs an API write while it is down.  It is never run during
# ordinary grading; tests/kubeadm-live-test.sh is the explicit opt-in caller.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../lib/grader.sh"
source "$SCRIPT_DIR/../../../lib/cell-grader.sh"

qid="${1:-ca-11}"
[ "$qid" = ca-11 ]
cell_grader_bind "$qid"
[ -z "$_CELL_GRADER_ERROR" ]
cell_manifest_load "$qid"
[ "$CELL_PROFILE" = kubeadm-ha ] && [ "$CELL_STATUS" = READY ]
cell_verify_topology "$qid"
cell_exact_ready_nodes cp1 cp2 cp3 worker1 worker2 worker3
cell_etcd_three_healthy_members
service_ip="$(kctx -n ha-survival get service survival-web \
  -o jsonpath='{.spec.clusterIP}')"
[[ "$service_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]

cp1_id="${CELL_CONTAINER_IDS[cp1]}"
run_id="$CELL_RUN_ID"
restore_cp1() {
  local running
  if _cell_docker container inspect "$cp1_id" >/dev/null 2>&1; then
    cell_verify_container_id "$qid" cp1 1 || return 1
    running="$(_cell_docker container inspect --format '{{.State.Running}}' "$cp1_id")"
    [ "$running" = true ] || _cell_docker container start "$cp1_id" >/dev/null
  fi
}
trap restore_cp1 EXIT

cell_verify_container_id "$qid" cp1
_cell_docker container stop --time 10 "$cp1_id" >/dev/null
cell_verify_container_id "$qid" cp1 1
[ "$(_cell_docker container inspect --format '{{.State.Running}}' "$cp1_id")" = false ]

ready=0
for _ in $(seq 1 60); do
  if cell_api_ready; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ]

# The successful write proves that the load balancer reached a surviving API
# server backed by an etcd quorum.  The in-cluster request separately proves
# workload/service data-path continuity.
proof="failover-${run_id:0:12}"
kctx -n ha-survival create configmap "$proof" \
  --from-literal=cp1-stopped=true >/dev/null
[ "$(kctx -n ha-survival get configmap "$proof" \
  -o jsonpath='{.data.cp1-stopped}')" = true ]

# Endpoint watches can briefly reconverge after the API/etcd leader changes.
# Use the Service's pre-sealed ClusterIP so this control-plane failover check is
# independent from where kubeadm happened to schedule the CoreDNS replicas.
# The existing Service data path must recover while cp1 remains stopped.
service_ready=0
for _ in $(seq 1 60); do
  cell_verify_container_id "$qid" cp1 1
  [ "$(_cell_docker container inspect --format '{{.State.Running}}' "$cp1_id")" = false ]
  if output="$(kctx -n ha-survival exec network-client -- \
      wget -qO- --timeout=5 "http://$service_ip" 2>/dev/null)" \
      && printf '%s' "$output" | grep -Fqi '<html'; then
    service_ready=1
    break
  fi
  sleep 2
done
[ "$service_ready" -eq 1 ] || die "Service ClusterIP path did not survive cp1 failover"
[ "$(_cell_docker container inspect --format '{{.State.Running}}' "$cp1_id")" = false ]

restore_cp1
trap - EXIT
ready=0
for _ in $(seq 1 90); do
  if cell_exact_ready_nodes cp1 cp2 cp3 worker1 worker2 worker3 \
      && cell_etcd_three_healthy_members; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" -eq 1 ] || die "cp1 did not rejoin the healthy HA topology"
printf '%s\n' "PASS ca-11 active failover: API write and Service path survived cp1 stop"
