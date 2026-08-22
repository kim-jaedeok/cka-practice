#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../lib/cell.sh"
source "$SCRIPT_DIR/package-cache.sh"

# Real kubeadm reset/package operations can legitimately exceed the generic
# 45-second Docker command bound. Keep them bounded, but give trusted cell
# preparation enough time to complete on modest WSL hosts.
export CKA_CELL_DOCKER_TIMEOUT="${CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-300}"

usage() {
  printf '%s\n' "usage: cell.sh up|down|status ca-11|ca-12|ca-06" >&2
  exit 2
}

profile_for() {
  case "$1" in
    ca-11) printf '%s\n' kubeadm-ha ;;
    ca-12) printf '%s\n' kubeadm-bootstrap ;;
    ca-06) printf '%s\n' kubeadm-upgrade ;;
    *) return 1 ;;
  esac
}

config_for() {
  case "$1" in
    kubeadm-ha) printf '%s/ha-kind.yaml\n' "$SCRIPT_DIR" ;;
    kubeadm-bootstrap) printf '%s/bootstrap-kind.yaml\n' "$SCRIPT_DIR" ;;
    kubeadm-upgrade) printf '%s/upgrade-kind.yaml\n' "$SCRIPT_DIR" ;;
    *) return 1 ;;
  esac
}

stage_ownership() {
  local qid="$1" role
  cell_manifest_load "$qid"
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    cell_exec "$qid" "$role" bash -c '
      set -eu
      install -d -m 0700 /opt/cka-cell /opt/cka
      umask 077
      printf "%s\n%s\n%s\n" "$1" "$2" "$3" > /opt/cka-cell/ownership
    ' _ "$CELL_RUN_ID" "$qid" "$role"
  done < <(cell_expected_roles "$CELL_PROFILE")
}

ensure_workload_images() {
  local qid="$1" role image expected actual
  kubeadm_workload_cache_verify \
    || die "locked workload image cache is missing; run cluster/cells/kubeadm/cache-packages.sh"
  cell_manifest_load "$qid"
  _cell_external_timeout 300s kind load image-archive --name "$CELL_CLUSTER_NAME" \
    "$KUBEADM_PACKAGE_CACHE/$KUBEADM_WORKLOAD_BUNDLE" >/dev/null \
    || die "workload image import failed or exceeded 300s"
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    for image in nginx busybox; do
      case "$image" in
        nginx)
          image="$KUBEADM_WORKLOAD_NGINX_IMAGE"
          expected="$KUBEADM_WORKLOAD_NGINX_IMAGE_ID"
          ;;
        busybox)
          image="$KUBEADM_WORKLOAD_BUSYBOX_IMAGE"
          expected="$KUBEADM_WORKLOAD_BUSYBOX_IMAGE_ID"
          ;;
      esac
      actual="$(cell_exec "$qid" "$role" crictl inspecti "$image" \
        | python3 -c '
import json, sys
value=(json.load(sys.stdin).get("status") or {}).get("id", "")
print(value) if isinstance(value, str) and value.startswith("sha256:") else sys.exit(1)
')" || return 1
      [ "$actual" = "$expected" ] \
        || die "locked workload image was not imported into $role: $image"
    done
  done < <(cell_expected_roles "$CELL_PROFILE")
}

preload_kubeadm_pause() {
  local qid="$1" role actual
  kubeadm_pause_cache_verify \
    || die "locked kubeadm pause image is missing; run cluster/cells/kubeadm/cache-packages.sh"
  cell_manifest_load "$qid" || return 1
  _cell_external_timeout 300s kind load image-archive --name "$CELL_CLUSTER_NAME" \
    "$KUBEADM_PACKAGE_CACHE/$KUBEADM_PAUSE_BUNDLE" >/dev/null \
    || die "pause image import failed or exceeded 300s"
  while IFS= read -r role; do
    [ "$role" = lb ] && continue
    actual="$(cell_exec "$qid" "$role" crictl inspecti "$KUBEADM_PAUSE_IMAGE" \
      | python3 -c '
import json, sys
value=(json.load(sys.stdin).get("status") or {}).get("id", "")
print(value) if isinstance(value, str) and value.startswith("sha256:") else sys.exit(1)
')" || return 1
    [ "$actual" = "$KUBEADM_PAUSE_IMAGE_ID" ] \
      || die "locked pause image was not imported into $role"
  done < <(cell_expected_roles "$CELL_PROFILE")
}

stage_bootstrap_cni() {
  local qid="$1"
  cell_manifest_load "$qid"
  cell_exec_script "$qid" cp1 "$SCRIPT_DIR/stage-bootstrap-assets.sh" \
    "$CELL_RUN_ID" "$qid"
}

prepare_bootstrap() {
  local qid="$1" role
  stage_ownership "$qid"
  ensure_workload_images "$qid"
  stage_bootstrap_cni "$qid"
  # Workers first; keep the API available until the final cp1 reset.
  for role in worker1 worker2 cp1; do
    cell_manifest_load "$qid"
    cell_exec_script "$qid" "$role" "$SCRIPT_DIR/blank-node.sh" \
      "$CELL_RUN_ID" "$qid" "$role"
  done
}

prepare_ha() {
  local qid="$1"
  stage_ownership "$qid"
  ensure_workload_images "$qid"
  bash "$SCRIPT_DIR/seed-ha.sh" "$qid"
}

prepare_upgrade() {
  local qid="$1"
  stage_ownership "$qid"
  ensure_workload_images "$qid"
  kubeadm_package_cache_verify \
    || die "real kubeadm package cache is missing or corrupt; run cluster/cells/kubeadm/cache-packages.sh"
  CKA_CELL_PACKAGE_CACHE="$KUBEADM_PACKAGE_CACHE" \
    CKA_CELL_UPGRADE_FROM_PACKAGE="$KUBEADM_PACKAGE_FROM_VERSION" \
    CKA_CELL_UPGRADE_TO_PACKAGE="$KUBEADM_PACKAGE_TO_VERSION" \
    bash "$SCRIPT_DIR/seed-upgrade.sh" "$qid"
}

up() {
  local qid="$1" profile config
  profile="$(profile_for "$qid")" || usage
  config="$(config_for "$profile")"
  if [ -e "$(cell_state_dir "$qid")" ]; then
    cell_destroy "$qid"
  fi
  cell_create "$qid" "$profile" "$config"
  preload_kubeadm_pause "$qid"
  case "$profile" in
    kubeadm-bootstrap) prepare_bootstrap "$qid" ;;
    kubeadm-ha) prepare_ha "$qid" ;;
    kubeadm-upgrade) prepare_upgrade "$qid" ;;
  esac
  cell_mark_ready "$qid"
  cell_status "$qid" "$profile"
}

action="${1:-}"
qid="${2:-}"
[ "$#" -eq 2 ] || usage
profile="$(profile_for "$qid")" || usage
case "$action" in
  up) up "$qid" ;;
  down) cell_destroy "$qid" ;;
  status) cell_status "$qid" "$profile" ;;
  *) usage ;;
esac
