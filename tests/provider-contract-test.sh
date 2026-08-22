#!/usr/bin/env bash
# Docker/Kubernetes-free safety contracts for the host-global LoadBalancer provider.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/addons.sh"

PASS=0
FAIL=0
check() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

contract_other_clusters_block_process_signals() (
  local signalled=0
  warn() { :; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_other_clusters_exist() { return 0; }
  kill() { signalled=1; return 0; }
  _cloud_provider_kind_signal_owned_term() { signalled=1; return 0; }

  ! _cloud_provider_kind_stop_unlocked \
    && [ "$signalled" -eq 0 ]
)

contract_other_clusters_block_restart_launch() (
  set -euo pipefail
  local temp launched=0 inventory_checked=0
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  CLOUD_PROVIDER_KIND_RUNTIME_DIR="$temp/runtime"
  CLOUD_PROVIDER_KIND_PID_FILE="$CLOUD_PROVIDER_KIND_RUNTIME_DIR/process"
  CLOUD_PROVIDER_KIND_LOG_FILE="$CLOUD_PROVIDER_KIND_RUNTIME_DIR/provider.log"
  mkdir "$CLOUD_PROVIDER_KIND_RUNTIME_DIR"
  warn() { :; }
  _cloud_provider_kind_prepare_runtime() { return 0; }
  cloud_provider_kind_binary_ok() { return 0; }
  addon_ok_cloud_provider_kind() { return 1; }
  _cloud_provider_kind_untracked_process_exists() { return 1; }
  _cloud_provider_kind_prepare_proxy_repair_if_needed() { return 0; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_other_clusters_exist() { inventory_checked=$((inventory_checked + 1)); return 0; }
  nohup() { launched=1; return 0; }

  ! cloud_provider_kind_start \
    && [ "$inventory_checked" -gt 0 ] \
    && [ "$launched" -eq 0 ]
)

contract_unknown_cluster_inventory_blocks_process_signals() (
  local signalled=0
  warn() { :; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_other_clusters_exist() { return 2; }
  kill() { signalled=1; return 0; }
  _cloud_provider_kind_signal_owned_term() { signalled=1; return 0; }

  ! _cloud_provider_kind_stop_unlocked \
    && [ "$signalled" -eq 0 ]
)

contract_stale_boot_record_is_reclaimed_without_signal() (
  set -euo pipefail
  local temp old_boot current_boot signalled=0
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  old_boot=11111111-1111-1111-1111-111111111111
  current_boot=22222222-2222-2222-2222-222222222222
  CLOUD_PROVIDER_KIND_PID_FILE="$temp/process"
  printf '4242|99|%s|v0.11.1|%064d\n' "$old_boot" 0 > "$CLOUD_PROVIDER_KIND_PID_FILE"
  _cloud_provider_kind_boot_id() { printf '%s' 22222222-2222-2222-2222-222222222222; }
  _cloud_provider_kind_untracked_process_exists() { return 1; }
  kill() { signalled=1; return 0; }

  _cloud_provider_kind_reclaim_stale_record \
    && [ ! -e "$CLOUD_PROVIDER_KIND_PID_FILE" ] \
    && [ "$signalled" -eq 0 ]
)

contract_proxy_readiness_uses_full_id_and_live_state() (
  local container_id other_id fixture_image_id container_name fake_running fake_paused fake_restarting
  container_id="$(printf 'a%.0s' {1..64})"
  other_id="$(printf 'b%.0s' {1..64})"
  fixture_image_id="sha256:$(printf 'c%.0s' {1..64})"
  container_name="/kindccm-$(printf '%s' 'cka/lb-shop/store-lb' | sha256sum | cut -c1-12)"
  fake_running=true
  fake_paused=false
  fake_restarting=false
  docker() {
    case "$1:$2" in
      image:inspect)
        printf '%s\n' "$fixture_image_id"
        ;;
      ps:-aq)
        [[ " $* " == *' --no-trunc '* ]] || return 1
        printf '%s\n' "$container_id"
        ;;
      container:inspect)
        if [[ "$*" == *'.State.Running'* ]]; then
          printf '%s|%s|%s|%s|%s\n' \
            "$container_id" "$fixture_image_id" "$fake_running" "$fake_paused" "$fake_restarting"
        else
          printf '%s|%s|cka|cka/lb-shop/store-lb\n' "$container_id" "$container_name"
        fi
        ;;
      *) return 1 ;;
    esac
  }

  cloud_provider_kind_cluster_proxy_images_ok cka || return 1
  fake_running=false
  ! cloud_provider_kind_cluster_proxy_images_ok cka || return 1
  fake_running=true
  fake_paused=true
  ! cloud_provider_kind_cluster_proxy_images_ok cka || return 1
  fake_paused=false

  docker() {
    case "$1:$2" in
      image:inspect) printf '%s\n' "$fixture_image_id" ;;
      ps:-aq) printf '%s\n' "$container_id" ;;
      container:inspect)
        if [[ "$*" == *'.State.Running'* ]]; then
          printf '%s|%s|true|false|false\n' "$other_id" "$fixture_image_id"
        else
          printf '%s|%s|cka|cka/lb-shop/store-lb\n' "$container_id" "$container_name"
        fi
        ;;
      *) return 1 ;;
    esac
  }
  ! cloud_provider_kind_cluster_proxy_images_ok cka
)

contract_confirmed_proxy_drift_is_repaired_only_when_safe() (
  local inventory_rc prepare_rc
  warn() { :; }
  cloud_provider_kind_cluster_proxy_images_ok() { return 1; }
  cluster_ready() { return 0; }
  cloud_provider_kind_verified_cluster_lb_ids() { printf '%064d\n' 1; }

  inventory_rc=1
  _cloud_provider_kind_other_clusters_exist() { return "$inventory_rc"; }
  if _cloud_provider_kind_prepare_proxy_repair_if_needed; then
    return 1
  else
    prepare_rc=$?
  fi
  [ "$prepare_rc" -eq 10 ] || return 1

  for inventory_rc in 0 2; do
    ! _cloud_provider_kind_prepare_proxy_repair_if_needed || return 1
  done
)

contract_proxy_repair_stops_before_exact_removal() (
  local events=""
  warn() { :; }
  _cloud_provider_kind_untracked_process_exists() { return 1; }
  _cloud_provider_kind_prepare_proxy_repair_if_needed() { return 10; }
  _cloud_provider_kind_stop_unlocked() { events="${events}stop "; }
  _cloud_provider_kind_lifecycle_mutation_allowed() { events="${events}sole "; }
  cloud_provider_kind_force_remove_cluster_lbs() {
    [ "$1" = cka ] || return 1
    events="${events}remove "
  }

  _cloud_provider_kind_quiesce_for_start \
    && [ "$events" = 'stop sole remove ' ]
)

contract_proxy_removal_preflights_complete_inventory() (
  local first second first_name removed=0
  first="$(printf 'a%.0s' {1..64})"
  second="$(printf 'b%.0s' {1..64})"
  first_name="/kindccm-$(printf '%s' 'cka/lb-shop/store-lb' | sha256sum | cut -c1-12)"
  warn() { :; }
  cloud_provider_kind_cluster_lb_ids() { printf '%s\n%s\n' "$first" "$second"; }
  docker() {
    case "$1:$2:$3" in
      container:inspect:--format)
        if [ "${@: -1}" = "$first" ]; then
          printf '%s|%s|cka|cka/lb-shop/store-lb\n' "$first" "$first_name"
        else
          printf '%s|/not-a-provider-container|cka|cka/lb-shop/other-lb\n' "$second"
        fi
        ;;
      container:rm:--force) removed=$((removed + 1)) ;;
      *) return 1 ;;
    esac
  }

  ! cloud_provider_kind_force_remove_cluster_lbs cka \
    && [ "$removed" -eq 0 ]
)

contract_proxy_removal_rejects_growing_inventory() (
  set -euo pipefail
  local temp counter first second removed=0
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  counter="$temp/calls"
  printf '0\n' > "$counter"
  first="$(printf 'a%.0s' {1..64})"
  second="$(printf 'b%.0s' {1..64})"
  warn() { :; }
  cloud_provider_kind_verified_cluster_lb_ids() {
    local calls
    calls="$(<"$counter")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$counter"
    printf '%s\n' "$first"
    [ "$calls" -eq 1 ] || printf '%s\n' "$second"
  }
  docker() {
    if [ "$1:$2" = container:rm ]; then
      removed=$((removed + 1))
      return 0
    fi
    return 1
  }

  ! cloud_provider_kind_force_remove_cluster_lbs cka \
    && [ "$removed" -eq 0 ]
)

contract_owned_stop_uses_pidfd_sealed_record() (
  set -euo pipefail
  local temp boot pid=4242 start=99 called=""
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  boot=22222222-2222-2222-2222-222222222222
  CLOUD_PROVIDER_KIND_PID_FILE="$temp/process"
  printf '%s|%s|%s|v0.11.1|%064d\n' "$pid" "$start" "$boot" 0 > "$CLOUD_PROVIDER_KIND_PID_FILE"
  warn() { :; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_lifecycle_mutation_allowed() { return 0; }
  _cloud_provider_kind_boot_id() { printf '%s' "$boot"; }
  _cloud_provider_kind_signal_owned_term() {
    called="$1|$2|$3"
    return 0
  }

  _cloud_provider_kind_stop_unlocked \
    && [ "$called" = "$pid|$start|$boot" ] \
    && [ ! -e "$CLOUD_PROVIDER_KIND_PID_FILE" ]
)

contract_pidfd_failure_never_discards_ownership_record() (
  set -euo pipefail
  local temp boot
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  boot=22222222-2222-2222-2222-222222222222
  CLOUD_PROVIDER_KIND_PID_FILE="$temp/process"
  printf '4242|99|%s|v0.11.1|%064d\n' "$boot" 0 > "$CLOUD_PROVIDER_KIND_PID_FILE"
  warn() { :; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_lifecycle_mutation_allowed() { return 0; }
  _cloud_provider_kind_boot_id() { printf '%s' "$boot"; }
  _cloud_provider_kind_signal_owned_term() { return 1; }

  ! _cloud_provider_kind_stop_unlocked \
    && [ -f "$CLOUD_PROVIDER_KIND_PID_FILE" ]
)

contract_cluster_appearing_before_signal_blocks_pidfd() (
  set -euo pipefail
  local temp boot lifecycle_calls=0 signalled=0
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  boot=22222222-2222-2222-2222-222222222222
  CLOUD_PROVIDER_KIND_PID_FILE="$temp/process"
  printf '4242|99|%s|v0.11.1|%064d\n' "$boot" 0 > "$CLOUD_PROVIDER_KIND_PID_FILE"
  warn() { :; }
  _cloud_provider_kind_reclaim_stale_record() { return 0; }
  _cloud_provider_kind_lifecycle_mutation_allowed() {
    lifecycle_calls=$((lifecycle_calls + 1))
    [ "$lifecycle_calls" -eq 1 ]
  }
  _cloud_provider_kind_boot_id() { printf '%s' "$boot"; }
  _cloud_provider_kind_signal_owned_term() { signalled=1; return 0; }

  ! _cloud_provider_kind_stop_unlocked \
    && [ "$lifecycle_calls" -eq 2 ] \
    && [ "$signalled" -eq 0 ] \
    && [ -f "$CLOUD_PROVIDER_KIND_PID_FILE" ]
)

contract_pidfd_helper_signals_only_sealed_child() (
  set -euo pipefail
  local binary child start boot
  binary="$(readlink -f "$(command -v python3)")"
  [ -x "$binary" ] || return 1
  "$binary" -c 'import time; time.sleep(30)' --gateway-channel disabled &
  child=$!
  trap 'kill "$child" >/dev/null 2>&1 || true; wait "$child" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 20); do
    [ -r "/proc/$child/stat" ] && break
    sleep 0.05
  done
  start="$(awk '{print $22}' "/proc/$child/stat")"
  boot="$(< /proc/sys/kernel/random/boot_id)"
  CLOUD_PROVIDER_KIND_BIN="$binary"

  _cloud_provider_kind_signal_owned_term "$child" "$start" "$boot" \
    && ! kill -0 "$child" 2>/dev/null
)

contract_untracked_provider_blocks_launch_without_signal() (
  local stopped=0 removed=0
  warn() { :; }
  _cloud_provider_kind_untracked_process_exists() { return 0; }
  _cloud_provider_kind_prepare_proxy_repair_if_needed() { return 10; }
  _cloud_provider_kind_stop_unlocked() { stopped=1; }
  cloud_provider_kind_force_remove_cluster_lbs() { removed=1; }

  ! _cloud_provider_kind_quiesce_for_start \
    && [ "$stopped" -eq 0 ] \
    && [ "$removed" -eq 0 ]
)

contract_unknown_process_inventory_blocks_launch() (
  local stopped=0 removed=0
  warn() { :; }
  _cloud_provider_kind_untracked_process_exists() { return 2; }
  _cloud_provider_kind_prepare_proxy_repair_if_needed() { return 10; }
  _cloud_provider_kind_stop_unlocked() { stopped=1; }
  cloud_provider_kind_force_remove_cluster_lbs() { removed=1; }

  ! _cloud_provider_kind_quiesce_for_start \
    && [ "$stopped" -eq 0 ] \
    && [ "$removed" -eq 0 ]
)

contract_external_provider_path_is_detected() (
  set -euo pipefail
  local temp fixture_pid
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  mkdir -p "$temp/external" "$temp/managed"
  cp "$(command -v sleep)" "$temp/external/cloud-provider-kind"
  "$temp/external/cloud-provider-kind" 30 &
  fixture_pid=$!
  trap 'kill "$fixture_pid" >/dev/null 2>&1 || true; wait "$fixture_pid" >/dev/null 2>&1 || true; rm -rf -- "$temp"' EXIT
  CLOUD_PROVIDER_KIND_BIN="$temp/managed/cloud-provider-kind"
  for _ in $(seq 1 20); do
    [ -r "/proc/$fixture_pid/cmdline" ] && break
    sleep 0.05
  done
  _cloud_provider_kind_untracked_process_exists
)

contract_candidate_datapath_tamper_is_fail() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  SN09_SENTINEL_BASELINE="$temp/sentinel.sha256"
  SN09_STORE_BASELINE="$temp/store.sha256"
  printf '%064d\n' 0 > "$SN09_SENTINEL_BASELINE"
  printf '%064d\n' 0 > "$SN09_STORE_BASELINE"
  SN09_SENTINEL_TAMPERED=0
  SN09_STORE_TAMPERED=0
  _G_INVALID=0
  _G_INVALID_REASONS=()
  sn09_fingerprint_matches() { [ "$1" = sentinel ]; }
  svc_has_endpoints() { return 0; }
  lb_http_contains_retry() { return 0; }

  sn09_check_trusted_baselines
  [ "$_G_INVALID" -eq 0 ] \
    && [ "$SN09_STORE_TAMPERED" -eq 1 ] \
    && ! sn09_candidate_guard
)

contract_candidate_port80_conflict_is_fail_not_invalid() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  SN09_SENTINEL_BASELINE="$temp/sentinel.sha256"
  SN09_STORE_BASELINE="$temp/store.sha256"
  printf '%064d\n' 0 > "$SN09_SENTINEL_BASELINE"
  printf '%064d\n' 0 > "$SN09_STORE_BASELINE"
  SN09_SENTINEL_TAMPERED=0
  SN09_STORE_TAMPERED=0
  _G_INVALID=0
  _G_INVALID_REASONS=()
  # The companion fingerprint contract proves that an extra port-80
  # LoadBalancer produces this store mismatch.  Even if that collision also
  # makes the sentinel unreachable, candidate evidence takes precedence.
  sn09_fingerprint_matches() { [ "$1" = sentinel ]; }
  svc_has_endpoints() { return 1; }
  lb_http_contains_retry() { return 1; }

  sn09_check_trusted_baselines
  [ "$_G_INVALID" -eq 0 ] \
    && [ "$SN09_STORE_TAMPERED" -eq 1 ] \
    && ! sn09_candidate_guard
)

contract_untouched_provider_outage_is_invalid() (
  set -euo pipefail
  local temp
  temp="$(mktemp -d)"
  case "$temp" in /tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$temp"' EXIT
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  SN09_SENTINEL_BASELINE="$temp/sentinel.sha256"
  SN09_STORE_BASELINE="$temp/store.sha256"
  printf '%064d\n' 0 > "$SN09_SENTINEL_BASELINE"
  printf '%064d\n' 0 > "$SN09_STORE_BASELINE"
  SN09_SENTINEL_TAMPERED=0
  SN09_STORE_TAMPERED=0
  _G_INVALID=0
  _G_INVALID_REASONS=()
  sn09_fingerprint_matches() { return 0; }
  svc_has_endpoints() { return 1; }
  lb_http_contains_retry() { return 0; }

  sn09_check_trusted_baselines
  [ "$_G_INVALID" -eq 1 ] \
    && [ "$SN09_SENTINEL_TAMPERED" -eq 0 ] \
    && [ "$SN09_STORE_TAMPERED" -eq 0 ]
)

contract_store_fingerprint_covers_supplied_datapath() {
  local setup="$ROOT/questions/services-networking/sn-09/setup.sh"
  local grade="$ROOT/questions/services-networking/sn-09/grade.sh"
  grep -Fq 'for ref in configmap/store-page deployment/store' "$setup" \
    && grep -Fq 'for ref in configmap/store-page deployment/store' "$grade" \
    && grep -Fq 'get networkpolicy -o json' "$setup" \
    && grep -Fq 'get networkpolicy -o json' "$grade" \
    && grep -Fq 'kctx get service -A -o json' "$setup" \
    && grep -Fq 'kctx get service -A -o json' "$grade" \
    && grep -Fq 'DockerPort80ProxyList' "$setup" \
    && grep -Fq 'DockerPort80ProxyList' "$grade" \
    && grep -Fq 'namespace == "lb-shop" and name == "store-lb"' "$setup" \
    && grep -Fq 'namespace == "lb-shop" and name == "store-lb"' "$grade"
}

contract_unexpected_port80_loadbalancer_changes_store_fingerprint() (
  set -euo pipefail
  local phase=baseline baseline candidate wrong
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  docker() {
    [ "$1:$2" = ps:-aq ] || return 1
  }
  kctx() {
    case "$*" in
      '-n lb-shop get configmap/store-page -o json')
        printf '%s\n' '{"kind":"ConfigMap","metadata":{"uid":"cm-1"},"data":{"index.html":"cka-sn09-loadbalancer"}}'
        ;;
      '-n lb-shop get deployment/store -o json')
        printf '%s\n' '{"kind":"Deployment","metadata":{"uid":"deploy-1"},"spec":{"replicas":2}}'
        ;;
      '-n lb-shop get networkpolicy -o json')
        printf '%s\n' '{"kind":"NetworkPolicyList","items":[]}'
        ;;
      'get service -A -o json')
        case "$phase" in
          baseline) printf '%s\n' '{"kind":"ServiceList","items":[]}' ;;
          candidate)
            printf '%s\n' '{"kind":"ServiceList","items":[{"kind":"Service","metadata":{"namespace":"lb-shop","name":"store-lb","uid":"candidate"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}}]}'
            ;;
          wrong)
            printf '%s\n' '{"kind":"ServiceList","items":[{"kind":"Service","metadata":{"namespace":"lb-shop","name":"store-lb","uid":"candidate"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}},{"kind":"Service","metadata":{"namespace":"default","name":"wrong-lb","uid":"wrong"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}}]}'
            ;;
        esac
        ;;
      *) return 1 ;;
    esac
  }

  baseline="$(sn09_resource_fingerprint store)"
  phase=candidate
  candidate="$(sn09_resource_fingerprint store)"
  phase=wrong
  wrong="$(sn09_resource_fingerprint store)"
  [ "$baseline" = "$candidate" ] && [ "$baseline" != "$wrong" ]
)

contract_generic_lists_are_source_typed_and_normalized() (
  set -euo pipefail
  local format=typed foreign=0 typed generic wrong
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  docker() {
    [ "$1:$2" = ps:-aq ] || return 1
  }
  kctx() {
    case "$*" in
      '-n lb-shop get configmap/store-page -o json')
        printf '%s\n' '{"kind":"ConfigMap","metadata":{"uid":"cm-1"},"data":{"index.html":"cka-sn09-loadbalancer"}}'
        ;;
      '-n lb-shop get deployment/store -o json')
        printf '%s\n' '{"kind":"Deployment","metadata":{"uid":"deploy-1"},"spec":{"replicas":2}}'
        ;;
      '-n lb-shop get networkpolicy -o json')
        printf '{"kind":"%s","items":[]}\n' \
          "$([ "$format" = typed ] && printf NetworkPolicyList || printf List)"
        ;;
      'get service -A -o json')
        if [ "$foreign" -eq 0 ]; then
          printf '{"kind":"%s","items":[{"kind":"Service","metadata":{"namespace":"lb-shop","name":"store-lb","uid":"candidate"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}}]}\n' \
            "$([ "$format" = typed ] && printf ServiceList || printf List)"
        else
          printf '{"kind":"%s","items":[{"kind":"Service","metadata":{"namespace":"lb-shop","name":"store-lb","uid":"candidate"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}},{"kind":"Service","metadata":{"namespace":"default","name":"wrong-lb","uid":"wrong"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}}]}\n' \
            "$([ "$format" = typed ] && printf ServiceList || printf List)"
        fi
        ;;
      *) return 1 ;;
    esac
  }

  typed="$(sn09_resource_fingerprint store)"
  format=generic
  generic="$(sn09_resource_fingerprint store)"
  foreign=1
  wrong="$(sn09_resource_fingerprint store)"
  [ "$typed" = "$generic" ] && [ "$generic" != "$wrong" ]
)

contract_generic_service_list_missing_uid_fails_closed() (
  set -euo pipefail
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  docker() {
    [ "$1:$2" = ps:-aq ] || return 1
  }
  kctx() {
    case "$*" in
      '-n lb-shop get configmap/store-page -o json')
        printf '%s\n' '{"kind":"ConfigMap","metadata":{"uid":"cm-1"},"data":{}}'
        ;;
      '-n lb-shop get deployment/store -o json')
        printf '%s\n' '{"kind":"Deployment","metadata":{"uid":"deploy-1"},"spec":{}}'
        ;;
      '-n lb-shop get networkpolicy -o json')
        printf '%s\n' '{"kind":"List","items":[]}'
        ;;
      'get service -A -o json')
        printf '%s\n' '{"kind":"List","items":[{"kind":"Service","metadata":{"namespace":"default","name":"missing-uid"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]}}]}'
        ;;
      *) return 1 ;;
    esac
  }

  ! sn09_resource_fingerprint store >/dev/null 2>&1
)

contract_orphaned_port80_proxy_changes_store_fingerprint() (
  set -euo pipefail
  local phase=baseline baseline orphan proxy_id proxy_name
  proxy_id="$(printf 'd%.0s' {1..64})"
  proxy_name="/kindccm-$(printf '%s' 'cka/default/wrong-lb' | sha256sum | cut -c1-12)"
  export CKA_QUESTION_SOURCE_ONLY=1
  source "$ROOT/questions/services-networking/sn-09/grade.sh"
  kctx() {
    case "$*" in
      '-n lb-shop get configmap/store-page -o json')
        printf '%s\n' '{"kind":"ConfigMap","metadata":{"uid":"cm-1"},"data":{"index.html":"cka-sn09-loadbalancer"}}'
        ;;
      '-n lb-shop get deployment/store -o json')
        printf '%s\n' '{"kind":"Deployment","metadata":{"uid":"deploy-1"},"spec":{"replicas":2}}'
        ;;
      '-n lb-shop get networkpolicy -o json')
        printf '%s\n' '{"kind":"NetworkPolicyList","items":[]}'
        ;;
      'get service -A -o json')
        printf '%s\n' '{"kind":"ServiceList","items":[]}'
        ;;
      *) return 1 ;;
    esac
  }
  docker() {
    case "$1:$2" in
      ps:-aq)
        [ "$phase" = baseline ] || printf '%s\n' "$proxy_id"
        ;;
      container:inspect)
        printf '{"Id":"%s","Name":"%s","Config":{"Labels":{"io.x-k8s.cloud-provider-kind.cluster":"cka","io.x-k8s.cloud-provider-kind.loadbalancer.name":"cka/default/wrong-lb"}},"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"80"}]}}}\n' \
          "$proxy_id" "$proxy_name"
        ;;
      *) return 1 ;;
    esac
  }

  baseline="$(sn09_resource_fingerprint store)"
  phase=orphan
  orphan="$(sn09_resource_fingerprint store)"
  [ "$baseline" != "$orphan" ]
)

contract_shell_syntax() {
  bash -n "$ROOT/lib/addons.sh" \
    && bash -n "$ROOT/questions/services-networking/sn-09/setup.sh" \
    && bash -n "$ROOT/questions/services-networking/sn-09/grade.sh" \
    && bash -n "$ROOT/questions/services-networking/sn-09/teardown.sh" \
    && bash -n "$ROOT/tests/provider-contract-test.sh"
}

check 'other KIND clusters block every provider stop/restart signal' \
  contract_other_clusters_block_process_signals
check 'other KIND clusters block launching a replacement provider' \
  contract_other_clusters_block_restart_launch
check 'unknown KIND inventory fails closed before provider signals' \
  contract_unknown_cluster_inventory_blocks_process_signals
check 'a valid previous-boot record is reclaimed without signalling its PID' \
  contract_stale_boot_record_is_reclaimed_without_signal
check 'kindccm readiness uses full immutable IDs and rejects stopped or paused containers' \
  contract_proxy_readiness_uses_full_id_and_live_state
check 'confirmed CKA proxy drift is repaired only when cluster inventory is safe' \
  contract_confirmed_proxy_drift_is_repaired_only_when_safe
check 'proxy repair stops the controller before exact-ID removal' \
  contract_proxy_repair_stops_before_exact_removal
check 'proxy removal preflights the complete inventory before any mutation' \
  contract_proxy_removal_preflights_complete_inventory
check 'proxy removal rejects inventory growth before any mutation' \
  contract_proxy_removal_rejects_growing_inventory
check 'owned provider shutdown passes one sealed record to the pidfd helper' \
  contract_owned_stop_uses_pidfd_sealed_record
check 'pidfd validation failure keeps the ownership record and sends no fallback signal' \
  contract_pidfd_failure_never_discards_ownership_record
check 'a KIND cluster appearing immediately before signal blocks pidfd use' \
  contract_cluster_appearing_before_signal_blocks_pidfd
check 'pidfd helper terminates an exactly sealed disposable child' \
  contract_pidfd_helper_signals_only_sealed_child
check 'an untracked provider blocks launch without signals or proxy removal' \
  contract_untracked_provider_blocks_launch_without_signal
check 'an unknown host process inventory blocks launch fail-closed' \
  contract_unknown_process_inventory_blocks_launch
check 'an external cloud-provider-kind binary path is detected before launch' \
  contract_external_provider_path_is_detected
check 'candidate NetworkPolicy/workload tampering remains a normal FAIL' \
  contract_candidate_datapath_tamper_is_fail
check 'a candidate-created port-80 LoadBalancer conflict is FAIL, never INVALID' \
  contract_candidate_port80_conflict_is_fail_not_invalid
check 'an untouched sentinel provider outage remains INVALID' \
  contract_untouched_provider_outage_is_invalid
check 'the trusted store fingerprint covers ConfigMap, Deployment and NetworkPolicies' \
  contract_store_fingerprint_covers_supplied_datapath
check 'an unexpected port-80 LoadBalancer changes the trusted store fingerprint' \
  contract_unexpected_port80_loadbalancer_changes_store_fingerprint
check 'generic Kubernetes Lists are source-typed and normalize like typed lists' \
  contract_generic_lists_are_source_typed_and_normalized
check 'a generic Service List with a missing UID fails closed' \
  contract_generic_service_list_missing_uid_fails_closed
check 'an orphaned candidate port-80 proxy changes the trusted store fingerprint' \
  contract_orphaned_port80_proxy_changes_store_fingerprint
check 'provider and sn-09 shell files parse successfully' contract_shell_syntax

printf '\nprovider-contract-test: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
