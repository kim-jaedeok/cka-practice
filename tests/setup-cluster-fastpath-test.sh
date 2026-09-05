#!/usr/bin/env bash
# Cluster-free contracts for setup's cached fast path and bounded node work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

PASS=0
FAIL=0
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cka-fastpath-test.XXXXXX")" || exit 1
trap 'rm -rf -- "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/node-tmp"
export TMPDIR="$TEST_TMP/node-tmp"

ok_test() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail_test() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
expect_success() {
  local label="$1"
  shift
  if "$@"; then ok_test "$label"; else fail_test "$label"; fi
}

ID0="$(printf 'a%.0s' {1..64})"
ID1="$(printf 'b%.0s' {1..64})"
ID2="$(printf 'c%.0s' {1..64})"
declare -a TEST_NODE_IDS=("$ID0" "$ID1" "$ID2")
declare -a TEST_NODE_NAMES=(cka-control-plane cka-worker cka-worker2)

_cluster_capture_verified_inventory() {
  CKA_VERIFIED_CLUSTER_IDS=("${TEST_NODE_IDS[@]}")
  CKA_VERIFIED_CLUSTER_NAMES=("${TEST_NODE_NAMES[@]}")
  CKA_VERIFIED_CLUSTER_STATES=(running running running)
}

_cluster_reverify_sealed_inventory() {
  local id
  printf 'reverify\n' >> "$NODE_REVERIFY_LOG"
  if [ "${NODE_REVERIFY_REQUIRE_TERMINAL_MARKERS:-0}" = 1 ]; then
    for id in "${TEST_NODE_IDS[@]}"; do
      [ -e "$NODE_LOG_DIR/worker-terminal-$id" ] || return 88
    done
  fi
  return "${NODE_REVERIFY_RC:-0}"
}

wait_for_path() { # <path>
  local path="$1" attempt
  for attempt in {1..1000}; do
    [ -e "$path" ] && return 0
    sleep 0.005
  done
  return 1
}

wait_for_all_worker_markers() { # <prefix>
  local prefix="$1" id attempt all_ready
  for attempt in {1..1000}; do
    all_ready=1
    for id in "${TEST_NODE_IDS[@]}"; do
      [ -e "$NODE_LOG_DIR/$prefix-$id" ] || all_ready=0
    done
    [ "$all_ready" -eq 1 ] && return 0
    sleep 0.005
  done
  return 1
}

node_fixture_reset() {
  NODE_LOG_DIR="$TEST_TMP/node-$1"
  rm -rf -- "$NODE_LOG_DIR"
  mkdir -p "$NODE_LOG_DIR"
  CACHED_REF="docker.io/library/cached:1"
  FAIL_PULL_ID=""
  FAIL_PULL_REF=""
  EDITOR_PRESENT_IDS=""
  EDITOR_INSTALL_OK_IDS=""
  CKA_REFRESH_PRELOAD_IMAGES=0
  NODE_REVERIFY_RC=0
  NODE_REVERIFY_REQUIRE_TERMINAL_MARKERS=0
  NODE_REVERIFY_LOG="$NODE_LOG_DIR/reverify"
  : > "$NODE_REVERIFY_LOG"
}

id_is_listed() { # <id> <space-separated-ids>
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

node_test_barrier() { # <id>
  local id="$1"
  : > "$NODE_LOG_DIR/entered-$id"
  wait_for_all_worker_markers entered
}

docker() {
  local id op ref script
  [ "${1:-}" = exec ] || return 98
  id="${2:-}"
  shift 2
  case "$id" in
    "$ID0"|"$ID1"|"$ID2") ;;
    *) return 97 ;;
  esac

  if [ ! -e "$NODE_LOG_DIR/barrier-passed-$id" ]; then
    node_test_barrier "$id" || return 96
    : > "$NODE_LOG_DIR/barrier-passed-$id"
  fi

  op="${1:-}"
  case "$op:${2:-}" in
    crictl:inspecti)
      ref="${3:-}"
      printf 'inspect|%s\n' "$ref" >> "$NODE_LOG_DIR/calls-$id"
      [ "$ref" = "$CACHED_REF" ]
      ;;
    crictl:pull)
      ref="${3:-}"
      printf 'pull|%s\n' "$ref" >> "$NODE_LOG_DIR/calls-$id"
      [ "$id" != "$FAIL_PULL_ID" ] || [ "$ref" != "$FAIL_PULL_REF" ]
      ;;
    sh:-c)
      script="${3:-}"
      case "$script" in
        'command -v vi >/dev/null 2>&1')
          printf 'editor-check\n' >> "$NODE_LOG_DIR/calls-$id"
          if id_is_listed "$id" "$EDITOR_PRESENT_IDS"; then
            : > "$NODE_LOG_DIR/worker-terminal-$id"
            return 0
          fi
          return 1
          ;;
        *'apt-get install -y vim nano'*)
          printf 'editor-install\n' >> "$NODE_LOG_DIR/calls-$id"
          : > "$NODE_LOG_DIR/worker-terminal-$id"
          id_is_listed "$id" "$EDITOR_INSTALL_OK_IDS"
          ;;
        *) return 95 ;;
      esac
      ;;
    *) return 94 ;;
  esac
}

ORIGINAL_NODE_DOCKER="$(declare -f docker)"
ORIGINAL_NODE_CAPTURE="$(declare -f _cluster_capture_verified_inventory)"
ORIGINAL_NODE_REVERIFY="$(declare -f _cluster_reverify_sealed_inventory)"

cached_images_and_failure_totals() {
  local summary id expected calls_file
  node_fixture_reset cached
  FAIL_PULL_ID="$ID1"
  FAIL_PULL_REF="docker.io/library/missing:2"
  EDITOR_PRESENT_IDS="$ID0"
  EDITOR_INSTALL_OK_IDS="$ID1"

  summary="$(prepare_cluster_nodes cached:1 missing:2 2>"$NODE_LOG_DIR/stderr")" \
    || return 1
  [ "$summary" = '1|1|1' ] || return 1
  [ -s "$NODE_LOG_DIR/stderr" ] || return 1

  for id in "${TEST_NODE_IDS[@]}"; do
    [ -e "$NODE_LOG_DIR/entered-$id" ] || return 1
    calls_file="$NODE_LOG_DIR/calls-$id"
    [ -f "$calls_file" ] || return 1
    ! grep -Fqx 'pull|docker.io/library/cached:1' "$calls_file" || return 1
    expected=$'inspect|docker.io/library/cached:1\ninspect|docker.io/library/missing:2\npull|docker.io/library/missing:2\neditor-check'
    if [ "$id" != "$ID0" ]; then
      expected+=$'\neditor-install'
    fi
    [ "$(<"$calls_file")" = "$expected" ] || return 1
  done
}

refresh_forces_serial_pulls() {
  local summary id expected calls_file
  node_fixture_reset refresh
  CKA_REFRESH_PRELOAD_IMAGES=1
  EDITOR_PRESENT_IDS="$ID0 $ID1 $ID2"

  summary="$(prepare_cluster_nodes cached:1 fresh:2 2>"$NODE_LOG_DIR/stderr")" \
    || return 1
  [ "$summary" = '0|0|0' ] || return 1
  expected=$'pull|docker.io/library/cached:1\npull|docker.io/library/fresh:2\neditor-check'
  for id in "${TEST_NODE_IDS[@]}"; do
    calls_file="$NODE_LOG_DIR/calls-$id"
    [ "$(<"$calls_file")" = "$expected" ] || return 1
    ! grep -q '^inspect|' "$calls_file" || return 1
  done
}

untrusted_tmpdir_is_ignored() {
  local real_mktemp summary argument
  node_fixture_reset trusted-tmp
  EDITOR_PRESENT_IDS="$ID0 $ID1 $ID2"
  real_mktemp="$(command -v mktemp)"
  MKTEMP_ARGUMENT_LOG="$NODE_LOG_DIR/mktemp-arguments"
  mktemp() {
    local made
    printf '%s\n' "$*" >> "$MKTEMP_ARGUMENT_LOG"
    made="$("$real_mktemp" "$@")" || return 1
    printf '%s\n' "$made"
  }

  summary="$(TMPDIR="$TEST_TMP/attacker-controlled" \
    prepare_cluster_nodes cached:1 2>"$NODE_LOG_DIR/stderr")"
  argument="$(<"$MKTEMP_ARGUMENT_LOG")"
  unset -f mktemp

  [ "$summary" = '0|0|0' ] \
    && [ "$argument" = '-d /tmp/cka-node-prep.XXXXXX' ]
}

node_generation_drift_after_workers_is_fatal() {
  local summary rc=0 id
  node_fixture_reset generation-drift
  EDITOR_PRESENT_IDS="$ID0 $ID1 $ID2"
  NODE_REVERIFY_REQUIRE_TERMINAL_MARKERS=1
  NODE_REVERIFY_RC=1

  summary="$(prepare_cluster_nodes cached:1 2>"$NODE_LOG_DIR/stderr")" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ "$summary" = '0|0|0' ] || return 1
  [ "$(grep -Fxc reverify "$NODE_REVERIFY_LOG")" -eq 1 ] || return 1
  for id in "${TEST_NODE_IDS[@]}"; do
    [ -e "$NODE_LOG_DIR/worker-terminal-$id" ] || return 1
  done
}

ORIGINAL_PREPARE_ONE="$(declare -f _prepare_cluster_node_one)"

all_workers_are_waited_after_failure() {
  local rc=0 id wait_count unique_wait_count
  node_fixture_reset reap
  WAIT_LOG="$NODE_LOG_DIR/waits"

  _prepare_cluster_node_one() {
    local id="$1"
    : > "$NODE_LOG_DIR/reap-entered-$id"
    wait_for_all_worker_markers reap-entered || return 80
    : > "$NODE_LOG_DIR/reap-done-$id"
    if [ "$id" = "$ID0" ]; then
      return 7
    fi
    printf '0|0|0\n'
  }
  wait() {
    printf '%s\n' "$1" >> "$WAIT_LOG"
    builtin wait "$@"
  }

  prepare_cluster_nodes image:1 >"$NODE_LOG_DIR/summary" \
    2>"$NODE_LOG_DIR/stderr" || rc=$?
  unset -f wait
  eval "$ORIGINAL_PREPARE_ONE"

  [ "$rc" -ne 0 ] || return 1
  wait_count="$(wc -l < "$WAIT_LOG")"
  unique_wait_count="$(sort -u "$WAIT_LOG" | wc -l)"
  [ "$wait_count" -eq 3 ] && [ "$unique_wait_count" -eq 3 ] || return 1
  for id in "${TEST_NODE_IDS[@]}"; do
    [ -e "$NODE_LOG_DIR/reap-entered-$id" ] || return 1
    [ -e "$NODE_LOG_DIR/reap-done-$id" ] || return 1
  done
}

signal_case_is_forwarded_and_reaped() { # <signal> <status> <case-name>
  local signal_name="$1" expected_status="$2" case_name="$3"
  local real_mktemp signal_tmp rc=0 failed=0 id worker_pid
  node_fixture_reset "signal-$case_name"
  real_mktemp="$(command -v mktemp)"
  signal_tmp="$("$real_mktemp" -d "/tmp/cka-node-prep-$case_name-test.XXXXXX")" \
    || return 1
  : > "$signal_tmp/unrelated-sentinel"
  SIGNAL_TMP="$signal_tmp"
  SIGNAL_RM_LOG="$NODE_LOG_DIR/rm-calls"
  SIGNAL_MKTEMP_LOG="$NODE_LOG_DIR/mktemp-calls"

  mktemp() {
    printf '%s\n' "$*" >> "$SIGNAL_MKTEMP_LOG"
    printf '%s\n' "$SIGNAL_TMP"
  }
  rm() {
    printf '%s\n' "$*" >> "$SIGNAL_RM_LOG"
    command rm "$@"
  }
  _prepare_cluster_node_one() {
    local id="$1" signal_marker coordinator_pid worker_shell_pid
    signal_marker="$NODE_LOG_DIR/signal-received-$id"
    worker_shell_pid="$BASHPID"
    printf '%s\n' "$worker_shell_pid" > "$NODE_LOG_DIR/signal-pid-$id"
    : > "$NODE_LOG_DIR/signal-started-$id"
    trap ': > "$signal_marker"; exit "$expected_status"' HUP INT TERM
    wait_for_all_worker_markers signal-started || return 81
    if [ "$id" = "$ID0" ]; then
      coordinator_pid="$(ps -o ppid= -p "$worker_shell_pid" | tr -d '[:space:]')"
      kill -s "$signal_name" "$coordinator_pid" || return 82
    fi
    while :; do sleep 1; done
  }

  prepare_cluster_nodes image:1 >"$NODE_LOG_DIR/summary" \
    2>"$NODE_LOG_DIR/stderr" || rc=$?

  [ "$rc" -eq "$expected_status" ] || failed=1
  [ "$(wc -l < "$SIGNAL_RM_LOG")" -eq 1 ] || failed=1
  [ -e "$signal_tmp/unrelated-sentinel" ] || failed=1
  for id in "${TEST_NODE_IDS[@]}"; do
    [ -e "$NODE_LOG_DIR/signal-received-$id" ] || failed=1
    [ ! -e "$signal_tmp/${id}.result" ] || failed=1
    worker_pid="$(<"$NODE_LOG_DIR/signal-pid-$id")"
    ! kill -0 "$worker_pid" 2>/dev/null || failed=1
  done
  for id in 0 1 2; do
    [ ! -e "$signal_tmp/$id.result" ] || failed=1
    [ ! -e "$signal_tmp/$id.log" ] || failed=1
  done

  unset -f mktemp rm
  eval "$ORIGINAL_PREPARE_ONE"
  command rm -rf -- "$signal_tmp"
  [ "$failed" -eq 0 ]
}

signals_are_forwarded_and_workers_are_reaped() {
  signal_case_is_forwarded_and_reaped HUP 129 hup \
    && signal_case_is_forwarded_and_reaped INT 130 int \
    && signal_case_is_forwarded_and_reaped TERM 143 term
}

etcd_fixture_enable() {
  _cluster_capture_verified_inventory() {
    printf 'capture\n' >> "$ETCD_CAPTURE_LOG"
    [ "${ETCD_CAPTURE_RC:-0}" -eq 0 ] || return "$ETCD_CAPTURE_RC"
    CKA_VERIFIED_CLUSTER_IDS=("${ETCD_CAPTURED_CP_ID:-$ID0}" "$ID1" "$ID2")
    CKA_VERIFIED_CLUSTER_NAMES=(cka-control-plane cka-worker cka-worker2)
    CKA_VERIFIED_CLUSTER_STATES=(running running running)
  }
  _cluster_reverify_sealed_inventory() {
    printf 'reverify\n' >> "$ETCD_REVERIFY_LOG"
    if [ "${ETCD_REVERIFY_MODE:-ok}" = drift ]; then
      CKA_VERIFIED_CLUSTER_IDS[0]="$ETCD_REPLACEMENT_ID"
      return 1
    fi
    return "${ETCD_REVERIFY_RC:-0}"
  }
  docker() {
    local target op script
    [ "${1:-}" = exec ] || return 98
    target="${2:-}"
    shift 2
    op="${1:-}"
    case "$op:${2:-}" in
      sh:-c)
        script="${3:-}"
        case "$script" in
          *'install -m 0755'*)
            printf '%s|mutation\n' "$target" >> "$ETCD_DOCKER_LOG"
            [ "${ETCD_MUTATION_RC:-0}" -eq 0 ] || return "$ETCD_MUTATION_RC"
            : > "$ETCD_TOOLS_READY"
            ;;
          *'command -v etcd >/dev/null'*)
            printf '%s|tool-check\n' "$target" >> "$ETCD_DOCKER_LOG"
            [ -e "$ETCD_TOOLS_READY" ]
            ;;
          *) return 97 ;;
        esac
        ;;
      crictl:ps)
        printf '%s|crictl-ps\n' "$target" >> "$ETCD_DOCKER_LOG"
        printf '%s\n' "$ETCD_CONTAINER_ID"
        ;;
      crictl:inspect)
        printf '%s|crictl-inspect\n' "$target" >> "$ETCD_DOCKER_LOG"
        [ "${ETCD_INSPECT_RC:-0}" -eq 0 ] || return "$ETCD_INSPECT_RC"
        printf '4242\n'
        ;;
      *) return 96 ;;
    esac
  }
}

etcd_fixture_reset() { # <name>
  ETCD_DIR="$TEST_TMP/etcd-$1"
  rm -rf -- "$ETCD_DIR"
  mkdir -p "$ETCD_DIR"
  ETCD_CAPTURE_LOG="$ETCD_DIR/capture"
  ETCD_REVERIFY_LOG="$ETCD_DIR/reverify"
  ETCD_DOCKER_LOG="$ETCD_DIR/docker"
  ETCD_TOOLS_READY="$ETCD_DIR/tools-ready"
  ETCD_CONTAINER_ID="$(printf 'd%.0s' {1..64})"
  ETCD_REPLACEMENT_ID="$(printf 'e%.0s' {1..64})"
  ETCD_CAPTURE_RC=0
  ETCD_CAPTURED_CP_ID="$ID0"
  ETCD_REVERIFY_RC=0
  ETCD_REVERIFY_MODE=ok
  ETCD_INSPECT_RC=0
  ETCD_MUTATION_RC=0
  : > "$ETCD_CAPTURE_LOG"
  : > "$ETCD_REVERIFY_LOG"
  : > "$ETCD_DOCKER_LOG"
}

etcd_tools_use_fresh_verified_immutable_id() {
  local failed=0
  etcd_fixture_enable

  etcd_fixture_reset already-ready
  : > "$ETCD_TOOLS_READY"
  node_etcdctl_ok || failed=1
  [ "$(grep -Fxc capture "$ETCD_CAPTURE_LOG")" -eq 1 ] || failed=1
  [ "$(<"$ETCD_DOCKER_LOG")" = "$ID0|tool-check" ] || failed=1

  etcd_fixture_reset install-success
  install_node_etcdctl >/dev/null 2>&1 || failed=1
  [ "$(grep -Fxc reverify "$ETCD_REVERIFY_LOG")" -eq 2 ] || failed=1
  [ "$(grep -Fxc "$ID0|mutation" "$ETCD_DOCKER_LOG")" -eq 1 ] || failed=1
  awk -F'|' -v expected="$ID0" '$1 != expected { bad=1 } END { exit bad }' \
    "$ETCD_DOCKER_LOG" || failed=1

  eval "$ORIGINAL_NODE_DOCKER"
  eval "$ORIGINAL_NODE_CAPTURE"
  eval "$ORIGINAL_NODE_REVERIFY"
  [ "$failed" -eq 0 ]
}

etcd_install_fails_closed_before_mutation() {
  local failed=0
  etcd_fixture_enable

  etcd_fixture_reset capture-failure
  ETCD_CAPTURE_RC=1
  install_node_etcdctl >/dev/null 2>&1 && failed=1
  [ ! -s "$ETCD_DOCKER_LOG" ] || failed=1

  etcd_fixture_reset malformed-full-id
  ETCD_CAPTURED_CP_ID=cka-control-plane
  install_node_etcdctl >/dev/null 2>&1 && failed=1
  [ ! -s "$ETCD_DOCKER_LOG" ] || failed=1

  etcd_fixture_reset inspect-failure
  ETCD_INSPECT_RC=1
  install_node_etcdctl >/dev/null 2>&1 && failed=1
  ! grep -Fq '|mutation' "$ETCD_DOCKER_LOG" || failed=1
  [ ! -s "$ETCD_REVERIFY_LOG" ] || failed=1

  etcd_fixture_reset identity-drift
  ETCD_REVERIFY_MODE=drift
  install_node_etcdctl >/dev/null 2>&1 && failed=1
  [ "$(grep -Fxc reverify "$ETCD_REVERIFY_LOG")" -eq 1 ] || failed=1
  ! grep -Fq '|mutation' "$ETCD_DOCKER_LOG" || failed=1

  eval "$ORIGINAL_NODE_DOCKER"
  eval "$ORIGINAL_NODE_CAPTURE"
  eval "$ORIGINAL_NODE_REVERIFY"
  [ "$failed" -eq 0 ]
}

write_setup_fixture_common() { # <destination>
  local destination="$1"
  cat > "$destination" <<'STUB'
CKA_PRELOAD_IMAGES_CSV='busybox:1.36,nginx:1.29'
CKA_CLUSTER_NAME=cka
CKA_ROOT="$CKA_FIXTURE_ROOT"
CKA_WORK_DIR="$CKA_FIXTURE_ROOT/work"
KIND_VERSION=v0.fixture
KIND_NODE_IMAGE=kindest/node:v1.fixture
CALICO_VERSION=v3.fixture
METRICS_SERVER_URL=https://fixture.invalid/metrics.yaml
METRICS_SERVER_MANIFEST_SHA256=fixture
GATEWAY_API_VERSION=v1.fixture
CLOUD_PROVIDER_KIND_VERSION=v0.fixture
HELM_VERSION=v3.fixture
HELM_LINUX_AMD64_SHA256=fixture
HELM_LINUX_ARM64_SHA256=fixture
C_BLD=''
C_RST=''

record() { printf '%s\n' "$*" >> "$FIXTURE_LOG"; }
info() { :; }
ok() { :; }
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }

docker() { [ "${1:-}" = info ]; }
kubectl() { :; }
curl() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
      shift
      : > "$1"
    fi
    shift
  done
}
sha256sum() { return 0; }
tar() { return 0; }
install() { return 0; }
flock() { return 0; }
nohup() { return 0; }
helm() {
  [ "${1:-}" = version ] || return 1
  printf '%s\n' "$HELM_VERSION"
}
kind() {
  case "${1:-}:${2:-}" in
    version:) printf 'kind %s\n' "$KIND_VERSION" ;;
    create:cluster) record 'kind:create' ;;
    *) return 1 ;;
  esac
}
kctx() { record "kctx:$*"; }

ensure_locked_kind() { :; }
kind_cluster_exists() { return "${FIXTURE_KIND_RC:-0}"; }
recover_cluster_nodes_ordered() { record recover; }
_wait_api() { record wait:api; }
cluster_matches_version_lock() { :; }
state_subdir_clear() { record "clear:$1"; }
configure_cluster_restart_policies() { record restart-policy; }

addon_ok_calico() { [ "${UNHEALTHY_ADDON:-}" != calico ]; }
addon_install_calico() { record install:calico; }
addon_wait_calico() { record wait:calico; }
addon_ok_metrics_server() { [ "${UNHEALTHY_ADDON:-}" != metrics ]; }
addon_install_metrics_server() { record install:metrics; }
addon_wait_metrics_server() { record wait:metrics; }
addon_ok_ingress_nginx() { [ "${UNHEALTHY_ADDON:-}" != ingress ]; }
addon_install_ingress_nginx() { record install:ingress; }
addon_wait_ingress_nginx() { record wait:ingress; }
addon_ok_gateway_api() { [ "${UNHEALTHY_ADDON:-}" != gateway ]; }
addon_install_gateway_api() { record install:gateway; }
addon_wait_gateway_api() { record wait:gateway; }
addon_ok_cloud_provider_kind() { [ "${UNHEALTHY_ADDON:-}" != provider ]; }
addon_install_cloud_provider_kind() { record install:provider; }
addon_wait_cloud_provider_kind() { record wait:provider; }
addon_ok_grader_client() { [ "${UNHEALTHY_ADDON:-}" != grader ]; }
addon_install_grader_client() { record install:grader; }
addon_wait_grader_client() { record wait:grader; }

prepare_cluster_nodes() {
  record prepare:nodes
  [ "${FIXTURE_PREPARE_RC:-0}" -eq 0 ] || return "$FIXTURE_PREPARE_RC"
  printf '0|0|0'
}
install_node_etcdctl() { record prepare:etcd; }
node_etcdctl_ok() { return 1; }
ssh_wrapper_ok() { return 1; }
ensure_shell_path() { return 1; }
STUB
}

setup_fixture_init() {
  SETUP_FIXTURE="$TEST_TMP/setup-fixture"
  rm -rf -- "$SETUP_FIXTURE"
  mkdir -p "$SETUP_FIXTURE/cluster" "$SETUP_FIXTURE/lib" \
    "$SETUP_FIXTURE/bin" "$SETUP_FIXTURE/home"
  cp "$ROOT/cluster/setup-cluster.sh" "$SETUP_FIXTURE/cluster/setup-cluster.sh"
  : > "$SETUP_FIXTURE/bin/ssh"
  write_setup_fixture_common "$SETUP_FIXTURE/lib/common.sh"
}

run_setup_case() { # <case-name> <kind-rc> <unhealthy-addon> [prepare-rc]
  local name="$1" kind_rc="$2" unhealthy="$3" prepare_rc="${4:-0}"
  CASE_LOG="$TEST_TMP/$name.log"
  CASE_STDOUT="$TEST_TMP/$name.stdout"
  CASE_STDERR="$TEST_TMP/$name.stderr"
  : > "$CASE_LOG"
  if env CKA_FIXTURE_ROOT="$SETUP_FIXTURE" FIXTURE_LOG="$CASE_LOG" \
      FIXTURE_KIND_RC="$kind_rc" UNHEALTHY_ADDON="$unhealthy" \
      FIXTURE_PREPARE_RC="$prepare_rc" \
      HOME="$SETUP_FIXTURE/home" \
      bash "$SETUP_FIXTURE/cluster/setup-cluster.sh" \
      >"$CASE_STDOUT" 2>"$CASE_STDERR"; then
    CASE_RC=0
  else
    CASE_RC=$?
  fi
}

healthy_existing_cluster_is_read_only_for_addons() {
  local wait_name
  setup_fixture_init || return 1
  run_setup_case setup-healthy 0 ''
  [ "$CASE_RC" -eq 0 ] || return 1
  ! grep -q '^install:' "$CASE_LOG" || return 1
  ! grep -Fqx 'kind:create' "$CASE_LOG" || return 1
  grep -Fqx recover "$CASE_LOG" || return 1
  grep -Fqx restart-policy "$CASE_LOG" || return 1
  [ "$(grep -Fxc 'wait:calico' "$CASE_LOG")" -eq 2 ] || return 1
  for wait_name in metrics ingress gateway provider grader; do
    grep -Fqx "wait:$wait_name" "$CASE_LOG" || return 1
  done
  grep -Fqx 'kctx:-n kube-system rollout status deploy/coredns --timeout=180s' \
    "$CASE_LOG"
}

each_unhealthy_addon_repairs_in_isolation() {
  local addon installs
  setup_fixture_init || return 1
  for addon in calico metrics ingress gateway provider grader; do
    run_setup_case "setup-unhealthy-$addon" 0 "$addon"
    [ "$CASE_RC" -eq 0 ] || return 1
    installs="$(grep '^install:' "$CASE_LOG" || true)"
    [ "$installs" = "install:$addon" ] || return 1
    grep -Fqx "wait:$addon" "$CASE_LOG" || return 1
  done
}

kind_inventory_error_never_creates() {
  setup_fixture_init || return 1
  run_setup_case setup-inventory-error 2 ''
  [ "$CASE_RC" -ne 0 ] || return 1
  ! grep -Fqx 'kind:create' "$CASE_LOG" || return 1
  ! grep -q '^install:' "$CASE_LOG"
}

new_cluster_clears_state_and_installs_every_addon() {
  local addon
  setup_fixture_init || return 1
  run_setup_case setup-new 1 ''
  [ "$CASE_RC" -eq 0 ] || return 1
  grep -Fqx kind:create "$CASE_LOG" || return 1
  ! grep -Fqx recover "$CASE_LOG" || return 1
  ! grep -Fqx wait:api "$CASE_LOG" || return 1
  for state_child in backup question-data status exam; do
    grep -Fqx "clear:$state_child" "$CASE_LOG" || return 1
  done
  for addon in calico metrics ingress gateway provider grader; do
    [ "$(grep -Fxc "install:$addon" "$CASE_LOG")" -eq 1 ] || return 1
  done
}

node_preparation_identity_failure_stops_setup() {
  setup_fixture_init || return 1
  run_setup_case setup-node-prep-failure 0 '' 1
  [ "$CASE_RC" -ne 0 ] || return 1
  grep -Fqx prepare:nodes "$CASE_LOG" || return 1
  ! grep -Fqx prepare:etcd "$CASE_LOG" || return 1
  grep -Fq '안전을 위해 중단합니다' "$CASE_STDERR"
}

expect_success 'cached images skip pulls; node failures aggregate without aborting' \
  cached_images_and_failure_totals
expect_success 'refresh mode pulls every image serially inside each node worker' \
  refresh_forces_serial_pulls
expect_success 'node preparation ignores caller-controlled TMPDIR' \
  untrusted_tmpdir_is_ignored
expect_success 'post-worker node generation drift makes preparation fail' \
  node_generation_drift_after_workers_is_fatal
expect_success 'all three concurrent workers are individually waited after failure' \
  all_workers_are_waited_after_failure
expect_success 'HUP/INT/TERM reach every worker, reap them, and clean exact files once' \
  signals_are_forwarded_and_workers_are_reaped
expect_success 'etcd checks and installation use a freshly verified control-plane ID' \
  etcd_tools_use_fresh_verified_immutable_id
expect_success 'etcd install fails closed on inspect failure or identity drift' \
  etcd_install_fails_closed_before_mutation
expect_success 'healthy existing cluster skips addon mutations but keeps final waits' \
  healthy_existing_cluster_is_read_only_for_addons
expect_success 'one unhealthy addon repairs only its own component' \
  each_unhealthy_addon_repairs_in_isolation
expect_success 'KIND inventory error is never treated as an absent cluster' \
  kind_inventory_error_never_creates
expect_success 'a new cluster clears prior state and installs every addon' \
  new_cluster_clears_state_and_installs_every_addon
expect_success 'node preparation identity failure stops setup before etcd mutation' \
  node_preparation_identity_failure_stops_setup

printf '\nsetup fast-path contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
