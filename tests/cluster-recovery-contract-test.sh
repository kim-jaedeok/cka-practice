#!/usr/bin/env bash
# Cluster-free Docker fixture for shared KIND node recovery and restart policies.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

PASS=0
FAIL=0
ok_test() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail_test() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
expect_success() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok_test "$label"; else fail_test "$label"; fi
}
expect_failure() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then fail_test "$label"; else ok_test "$label"; fi
}

CP_ID="$(printf 'a%.0s' {1..64})"
WORKER_ID="$(printf 'b%.0s' {1..64})"
WORKER2_ID="$(printf 'c%.0s' {1..64})"
EXTRA_ID="$(printf 'd%.0s' {1..64})"
NETWORK_ID="$(printf 'e%.0s' {1..64})"
IMAGE_ID="sha256:$(printf 'f%.0s' {1..64})"

declare -a F_IDS=()
declare -a F_EXTRA_IDS=()
declare -a F_START_LOG=()
declare -a F_UPDATE_LOG=()
declare -A F_NAME=()
declare -A F_ROLE=()
declare -A F_CLUSTER=()
declare -A F_CONFIG_IMAGE=()
declare -A F_IMAGE_ID=()
declare -A F_STATE=()
declare -A F_PAUSED=()
declare -A F_RESTARTING=()
declare -A F_NETWORK_MODE=()
declare -A F_NETWORK_COUNT=()
declare -A F_NETWORK_ID=()
declare -A F_POLICY=()
declare -A F_INCLUDED=()
F_FAIL_START_ID=""
F_FAIL_UPDATE_POLICY=""
F_ACTUAL_NETWORK_ID="$NETWORK_ID"
F_INSERT_EXTRA_AFTER_START_ID=""
F_REPLACE_NETWORK_AFTER_START_ID=""
F_KIND_CLUSTERS="$CKA_CLUSTER_NAME"
F_KIND_GET_CLUSTERS_RC=0

reset_fixture() {
  local id
  F_IDS=("$CP_ID" "$WORKER_ID" "$WORKER2_ID")
  F_EXTRA_IDS=()
  F_START_LOG=()
  F_UPDATE_LOG=()
  F_NAME=(); F_ROLE=(); F_CLUSTER=(); F_CONFIG_IMAGE=(); F_IMAGE_ID=()
  F_STATE=(); F_PAUSED=(); F_RESTARTING=(); F_NETWORK_MODE=()
  F_NETWORK_COUNT=(); F_NETWORK_ID=(); F_POLICY=(); F_INCLUDED=()
  F_NAME[$CP_ID]="${CKA_CLUSTER_NAME}-control-plane"
  F_NAME[$WORKER_ID]="${CKA_CLUSTER_NAME}-worker"
  F_NAME[$WORKER2_ID]="${CKA_CLUSTER_NAME}-worker2"
  F_ROLE[$CP_ID]=control-plane
  F_ROLE[$WORKER_ID]=worker
  F_ROLE[$WORKER2_ID]=worker
  for id in "${F_IDS[@]}"; do
    F_CLUSTER[$id]="$CKA_CLUSTER_NAME"
    F_CONFIG_IMAGE[$id]="$KIND_NODE_IMAGE"
    F_IMAGE_ID[$id]="$IMAGE_ID"
    F_STATE[$id]=running
    F_PAUSED[$id]=false
    F_RESTARTING[$id]=false
    F_NETWORK_MODE[$id]=kind
    F_NETWORK_COUNT[$id]=1
    F_NETWORK_ID[$id]="$NETWORK_ID"
    F_POLICY[$id]=no
    F_INCLUDED[$id]=1
  done
  F_FAIL_START_ID=""
  F_FAIL_UPDATE_POLICY=""
  F_ACTUAL_NETWORK_ID="$NETWORK_ID"
  F_INSERT_EXTRA_AFTER_START_ID=""
  F_REPLACE_NETWORK_AFTER_START_ID=""
  F_KIND_CLUSTERS="$CKA_CLUSTER_NAME"
  F_KIND_GET_CLUSTERS_RC=0
}

kind() {
  [ "${1:-}" = get ] && [ "${2:-}" = clusters ] || return 98
  [ "$F_KIND_GET_CLUSTERS_RC" -eq 0 ] || return "$F_KIND_GET_CLUSTERS_RC"
  [ -n "$F_KIND_CLUSTERS" ] && printf '%s\n' "$F_KIND_CLUSTERS"
  return 0
}

fake_resolve_id() {
  local target="$1" id
  for id in "${F_IDS[@]}" "${F_EXTRA_IDS[@]}"; do
    if [ "$target" = "$id" ] || [ "$target" = "${F_NAME[$id]:-}" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

docker() {
  local family="${1:-}" action="${2:-}" format="" target="" id="" running=false policy=""
  shift 2 2>/dev/null || return 98
  case "$family:$action" in
    network:inspect)
      [ "${1:-}" = --format ] && format="${2:-}" && target="${3:-}" || return 98
      [ "$target" = kind ] || [ "$target" = "$F_ACTUAL_NETWORK_ID" ] || return 1
      printf '%s|kind|END\n' "$F_ACTUAL_NETWORK_ID"
      ;;
    image:inspect)
      [ "${1:-}" = --format ] && format="${2:-}" && target="${3:-}" || return 98
      [ "$target" = "$KIND_NODE_IMAGE" ] || return 1
      printf '%s|END\n' "$IMAGE_ID"
      ;;
    container:inspect)
      [ "${1:-}" = --format ] && format="${2:-}" && target="${3:-}" || return 98
      id="$(fake_resolve_id "$target")" || return 1
      if [[ "$format" == *RestartPolicy.Name* ]]; then
        printf '%s|%s|END\n' "$id" "${F_POLICY[$id]}"
        return 0
      fi
      [ "${F_STATE[$id]}" = running ] && running=true
      printf '%s|/%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|true|%s|END\n' \
        "$id" "${F_NAME[$id]}" "${F_CLUSTER[$id]}" "${F_ROLE[$id]}" \
        "${F_CONFIG_IMAGE[$id]}" "${F_IMAGE_ID[$id]}" "${F_STATE[$id]}" \
        "$running" "${F_PAUSED[$id]}" "${F_RESTARTING[$id]}" \
        "${F_NETWORK_MODE[$id]}" "${F_NETWORK_COUNT[$id]}" "${F_NETWORK_ID[$id]}"
      ;;
    container:ls)
      for id in "${F_IDS[@]}" "${F_EXTRA_IDS[@]}"; do
        [ "${F_INCLUDED[$id]:-0}" = 1 ] && printf '%s\n' "$id"
      done
      ;;
    container:start)
      [ "$#" -eq 1 ] || return 98
      id="$1"
      [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 97
      [ "$id" != "$F_FAIL_START_ID" ] || return 1
      fake_resolve_id "$id" >/dev/null || return 1
      F_START_LOG+=("$id")
      F_STATE[$id]=running
      F_PAUSED[$id]=false
      F_RESTARTING[$id]=false
      F_NETWORK_ID[$id]="$NETWORK_ID"
      if [ "$id" = "$F_INSERT_EXTRA_AFTER_START_ID" ]; then
        F_EXTRA_IDS=("$EXTRA_ID")
        F_NAME[$EXTRA_ID]=foreign
        F_INCLUDED[$EXTRA_ID]=1
      fi
      if [ "$id" = "$F_REPLACE_NETWORK_AFTER_START_ID" ]; then
        F_ACTUAL_NETWORK_ID="$(printf '9%.0s' {1..64})"
      fi
      ;;
    container:update)
      policy="${1#--restart=}"
      [ "$1" = "--restart=$policy" ] || return 98
      shift
      [ "$#" -gt 0 ] || return 98
      [ "$policy" != "$F_FAIL_UPDATE_POLICY" ] || return 1
      F_UPDATE_LOG+=("$policy:$*")
      for id in "$@"; do
        [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 97
        fake_resolve_id "$id" >/dev/null || return 1
        F_POLICY[$id]="$policy"
      done
      ;;
    *) return 98 ;;
  esac
}

all_stopped_recovery() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  F_NETWORK_ID[$CP_ID]=""
  F_NETWORK_ID[$WORKER_ID]=""
  F_NETWORK_ID[$WORKER2_ID]=""
  recover_cluster_nodes_ordered || return 1
  [ "${F_START_LOG[*]}" = "$WORKER_ID $CP_ID $WORKER2_ID" ] \
    && [ "${F_STATE[$CP_ID]} ${F_STATE[$WORKER_ID]} ${F_STATE[$WORKER2_ID]}" = \
      "running running running" ]
}

prefix_recovery() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  recover_cluster_nodes_ordered || return 1
  [ "${F_START_LOG[*]}" = "$CP_ID $WORKER2_ID" ]
}

all_running_is_read_only() {
  reset_fixture
  recover_cluster_nodes_ordered || return 1
  [ "${#F_START_LOG[@]}" -eq 0 ] && [ "${#F_UPDATE_LOG[@]}" -eq 0 ]
}

reject_without_start() {
  if recover_cluster_nodes_ordered >/dev/null 2>&1; then return 1; fi
  [ "${#F_START_LOG[@]}" -eq 0 ]
}

reject_extra() {
  reset_fixture
  F_EXTRA_IDS=("$EXTRA_ID")
  F_NAME[$EXTRA_ID]=foreign
  F_INCLUDED[$EXTRA_ID]=1
  reject_without_start
}

reject_missing_inventory() {
  reset_fixture
  F_INCLUDED[$WORKER2_ID]=0
  reject_without_start
}

reject_wrong_identity() {
  reset_fixture
  F_ROLE[$WORKER2_ID]=control-plane
  reject_without_start
}

reject_name_cluster_and_config_image_drift() {
  reset_fixture
  F_NAME[$CP_ID]=renamed-control-plane
  reject_without_start || return 1
  reset_fixture
  F_CLUSTER[$WORKER_ID]=foreign-cluster
  reject_without_start || return 1
  reset_fixture
  F_CONFIG_IMAGE[$WORKER2_ID]=kindest/node:unlocked
  reject_without_start
}

reject_wrong_locked_image() {
  reset_fixture
  F_IMAGE_ID[$WORKER_ID]="sha256:$(printf '0%.0s' {1..64})"
  reject_without_start
}

reject_wrong_network() {
  reset_fixture
  F_NETWORK_MODE[$WORKER_ID]=bridge
  reject_without_start || return 1
  reset_fixture
  F_NETWORK_COUNT[$WORKER_ID]=2
  reject_without_start || return 1
  reset_fixture
  F_NETWORK_ID[$WORKER_ID]="$(printf '8%.0s' {1..64})"
  reject_without_start
}

reject_paused_or_restarting() {
  reset_fixture
  F_PAUSED[$CP_ID]=true
  reject_without_start || return 1
  reset_fixture
  F_STATE[$WORKER_ID]=restarting
  F_RESTARTING[$WORKER_ID]=true
  reject_without_start
}

reject_unknown_state() {
  reset_fixture
  F_STATE[$WORKER_ID]=created
  reject_without_start
}

reject_nonprefix_partial() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  # worker and worker2 running is not a prefix of worker -> cp -> worker2.
  reject_without_start
}

start_failure_is_fatal() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  F_FAIL_START_ID="$CP_ID"
  if recover_cluster_nodes_ordered >/dev/null 2>&1; then return 1; fi
  [ "${F_START_LOG[*]}" = "$WORKER_ID" ] && [ "${F_STATE[$WORKER2_ID]}" = exited ]
}

toctou_extra_is_blocked_after_verified_prefix() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  F_INSERT_EXTRA_AFTER_START_ID="$WORKER_ID"
  if recover_cluster_nodes_ordered >/dev/null 2>&1; then return 1; fi
  [ "${F_START_LOG[*]}" = "$WORKER_ID" ] \
    && [ "${F_STATE[$CP_ID]} ${F_STATE[$WORKER2_ID]}" = "exited exited" ]
}

toctou_network_replacement_is_blocked() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  F_REPLACE_NETWORK_AFTER_START_ID="$WORKER_ID"
  if recover_cluster_nodes_ordered >/dev/null 2>&1; then return 1; fi
  [ "${F_START_LOG[*]}" = "$WORKER_ID" ] \
    && [ "${F_STATE[$CP_ID]} ${F_STATE[$WORKER2_ID]}" = "exited exited" ]
}

repair_orders_recovery_before_api() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  _wait_api() {
    [ "${F_STATE[$CP_ID]} ${F_STATE[$WORKER_ID]} ${F_STATE[$WORKER2_ID]}" = \
      "running running running" ]
  }
  ensure_addons() { printf '0'; }
  repair_cluster || return 1
  [ "${F_START_LOG[*]}" = "$WORKER_ID $CP_ID $WORKER2_ID" ]
}

missing_cluster_fails_before_node_inspect() {
  local output
  reset_fixture
  F_KIND_CLUSTERS=""
  if output="$(repair_cluster 2>&1)"; then return 1; fi
  grep -Fq "KIND 클러스터 '$CKA_CLUSTER_NAME'가 없습니다" <<< "$output" \
    && ! grep -Fq 'container를 정확히 inspect하지 못했습니다' <<< "$output" \
    && [ "${#F_START_LOG[@]}" -eq 0 ]
}

kind_inventory_failure_is_distinct() {
  local output
  reset_fixture
  F_KIND_GET_CLUSTERS_RC=1
  if output="$(repair_cluster 2>&1)"; then return 1; fi
  grep -Fq 'KIND 클러스터 inventory를 읽지 못했습니다' <<< "$output" \
    && ! grep -Fq 'container를 정확히 inspect하지 못했습니다' <<< "$output" \
    && [ "${#F_START_LOG[@]}" -eq 0 ]
}

restart_policy_is_exact_and_idempotent() {
  reset_fixture
  F_POLICY[$CP_ID]=unless-stopped
  F_POLICY[$WORKER_ID]=no
  F_POLICY[$WORKER2_ID]=unless-stopped
  configure_cluster_restart_policies || return 1
  [ "${F_UPDATE_LOG[0]:-}" = "no:$CP_ID $WORKER2_ID" ] \
    && [ "${F_UPDATE_LOG[1]:-}" = "unless-stopped:$WORKER_ID" ] \
    && [ "${F_POLICY[$CP_ID]} ${F_POLICY[$WORKER_ID]} ${F_POLICY[$WORKER2_ID]}" = \
      "no unless-stopped no" ] || return 1
  F_UPDATE_LOG=()
  configure_cluster_restart_policies || return 1
  [ "${#F_UPDATE_LOG[@]}" -eq 0 ]
}

policy_refuses_stopped_nodes() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  if configure_cluster_restart_policies >/dev/null 2>&1; then return 1; fi
  [ "${#F_UPDATE_LOG[@]}" -eq 0 ]
}

policy_update_failure_is_not_ignored() {
  reset_fixture
  F_POLICY[$CP_ID]=unless-stopped
  F_FAIL_UPDATE_POLICY=no
  if configure_cluster_restart_policies >/dev/null 2>&1; then return 1; fi
  [ "${#F_UPDATE_LOG[@]}" -eq 0 ] && [ "${F_POLICY[$CP_ID]}" = unless-stopped ]
}

readonly_gate_never_recovers() {
  reset_fixture
  F_STATE[$CP_ID]=exited
  F_STATE[$WORKER_ID]=exited
  F_STATE[$WORKER2_ID]=exited
  _wait_api() { return 1; }
  if require_cluster_readonly >/dev/null 2>&1; then return 1; fi
  [ "${#F_START_LOG[@]}" -eq 0 ] && [ "${#F_UPDATE_LOG[@]}" -eq 0 ]
}

setup_order_is_static() {
  local setup="$ROOT/cluster/setup-cluster.sh" recovery_line wait_line
  recovery_line="$(grep -n '^[[:space:]]*recover_cluster_nodes_ordered' "$setup" | head -1 | cut -d: -f1)"
  wait_line="$(grep -n '^[[:space:]]*_wait_api' "$setup" | head -1 | cut -d: -f1)"
  [ -n "$recovery_line" ] && [ -n "$wait_line" ] \
    && [ "$recovery_line" -lt "$wait_line" ] \
    && grep -Fq 'configure_cluster_restart_policies' "$setup" \
    && ! grep -Eq 'docker (container )?update --restart=unless-stopped.*control-plane' "$setup"
}

expect_success 'all stopped nodes start by immutable ID in worker/cp/worker2 order' all_stopped_recovery
expect_success 'safe partial prefix resumes at control-plane then worker2' prefix_recovery
expect_success 'all-running recovery path performs no Docker mutation' all_running_is_read_only
expect_success 'extra same-cluster container is rejected before mutation' reject_extra
expect_success 'missing inventory member is rejected before mutation' reject_missing_inventory
expect_success 'wrong role label is rejected before mutation' reject_wrong_identity
expect_success 'name, cluster label, and Config.Image drift are rejected' reject_name_cluster_and_config_image_drift
expect_success 'wrong immutable image ID is rejected before mutation' reject_wrong_locked_image
expect_success 'wrong network identity is rejected before mutation' reject_wrong_network
expect_success 'paused and restarting states are rejected before mutation' reject_paused_or_restarting
expect_success 'unknown Docker state is rejected before mutation' reject_unknown_state
expect_success 'non-prefix partial start state is rejected before mutation' reject_nonprefix_partial
expect_success 'start failure stops later ordered mutations' start_failure_is_fatal
expect_success 'TOCTOU extra insertion stops after the verified prefix' toctou_extra_is_blocked_after_verified_prefix
expect_success 'TOCTOU network replacement stops after the verified prefix' toctou_network_replacement_is_blocked
expect_success 'mutable repair recovers nodes before waiting for API' repair_orders_recovery_before_api
expect_success 'missing cluster fails before node identity inspection' missing_cluster_fails_before_node_inspect
expect_success 'KIND inventory failure is distinct from missing nodes' kind_inventory_failure_is_distinct
expect_success 'restart policies use exact IDs and are idempotent' restart_policy_is_exact_and_idempotent
expect_success 'restart policy mutation refuses stopped nodes' policy_refuses_stopped_nodes
expect_success 'restart policy update failure is propagated' policy_update_failure_is_not_ignored
expect_success 'readonly gate never starts or updates containers' readonly_gate_never_recovers
expect_success 'existing setup invokes recovery before API wait' setup_order_is_static

printf '\ncluster recovery contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
