#!/usr/bin/env bash
# 채점 공통 계약의 빠른 unit/static 검사. 실제 클러스터가 없어도 실행 가능하다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/grader.sh"

# Windows Git Bash rewrites arguments such as /store before launching a native
# Python executable. Preserve JSON/API path arguments; WSL ignores this MSYS
# compatibility variable. Fall back to `python` only when python3 is unusable.
if python3 -c 'import json' >/dev/null 2>&1; then
  CONTRACT_PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  CONTRACT_PYTHON_BIN="$(command -v python)"
else
  printf 'contract-test: Python interpreter unavailable\n' >&2
  exit 1
fi
python3() { MSYS2_ARG_CONV_EXCL='*' "$CONTRACT_PYTHON_BIN" "$@"; }

PASS_COUNT=0
FAIL_COUNT=0
FAILED=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED+=("$1"); printf '  ✗ %s\n' "$1"; }

check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# grade_init/finish를 클러스터나 상태 파일 없이 검사하기 위한 stub.
CT_CLUSTER_RC=0
CT_ADDON_CALLS=0
CT_STATE_ID=""
CT_STATE_VALUE=""
kubectl() { :; }
cluster_ready() { return "$CT_CLUSTER_RC"; }
ensure_addons() { CT_ADDON_CALLS=$((CT_ADDON_CALLS + 1)); }
state_set() { CT_STATE_ID="$1"; CT_STATE_VALUE="$2"; }

contract_grade_pass() {
  local rc=0
  CT_CLUSTER_RC=0; CT_STATE_ID=""; CT_STATE_VALUE=""
  grade_init contract-pass >/dev/null
  criterion 2 "true criterion" "true" >/dev/null
  grade_finish >/dev/null || rc=$?
  [ "$rc" -eq 0 ] && [ "$_G_RESULT" = PASS ] && \
    [ "$CT_STATE_ID" = contract-pass ] && [ "$CT_STATE_VALUE" = graded:2/2 ]
}

contract_grade_fail() {
  local rc=0
  CT_CLUSTER_RC=0; CT_STATE_ID=""; CT_STATE_VALUE=""
  grade_init contract-fail >/dev/null
  criterion 2 "false criterion" "false" >/dev/null
  grade_finish >/dev/null || rc=$?
  [ "$rc" -eq 1 ] && [ "$_G_RESULT" = FAIL ] && \
    [ "$CT_STATE_ID" = contract-fail ] && [ "$CT_STATE_VALUE" = graded:0/2 ]
}

contract_grade_invalid() {
  local rc=0
  CT_CLUSTER_RC=1; CT_STATE_ID=""; CT_STATE_VALUE=""
  grade_init contract-invalid >/dev/null
  criterion 2 "must not run" "true" >/dev/null
  grade_finish >/dev/null || rc=$?
  CT_CLUSTER_RC=0
  [ "$rc" -eq 2 ] && [ "$_G_RESULT" = INVALID ] && \
    [ "$CT_STATE_ID" = contract-invalid ] && \
    [[ "$CT_STATE_VALUE" == invalid:*cluster\ API\ unavailable* ]]
}

printf '%s\n' "══ grader result contract ══"
check "full score => PASS and graded:E/M" contract_grade_pass
check "partial score => FAIL and graded:E/M" contract_grade_fail
check "API failure => INVALID, not candidate FAIL" contract_grade_invalid
check "grading never invokes addon repair" test "$CT_ADDON_CALLS" -eq 0

# 실패 출력에 Address가 포함돼도 nslookup의 non-zero status를 존중해야 한다.
_grader_client_require() { return 0; }
CT_KCTX_RC=0
CT_KCTX_OUTPUT=""
kctx() { printf '%s\n' "$CT_KCTX_OUTPUT"; return "$CT_KCTX_RC"; }

contract_dns_rejects_error_output() {
  CT_KCTX_RC=1
  CT_KCTX_OUTPUT=$'Server: 10.96.0.10\nAddress: 10.96.0.10:53\n** server can\047t find missing: NXDOMAIN'
  if dns_resolves missing.example; then CT_KCTX_RC=0; return 1; fi
  CT_KCTX_RC=0
  return 0
}

contract_dns_accepts_success() {
  CT_KCTX_RC=0
  CT_KCTX_OUTPUT=$'Name: kubernetes.default.svc.cluster.local\nAddress: 10.96.0.1'
  dns_resolves kubernetes.default.svc.cluster.local
}

printf '%s\n' "══ DNS and negative-network contract ══"
check "NXDOMAIN output with server Address does not pass" contract_dns_rejects_error_output
check "successful nslookup status passes" contract_dns_accepts_success

contract_source_dns_failure_is_candidate_fail() {
  local rc=0
  _G_INVALID=0; _G_INVALID_REASONS=()
  CT_GRADER_DNS_RC=0; CT_SOURCE_DNS_RC=1
  kctx() {
    if [[ "$*" == *"cka-system"* ]]; then return "$CT_GRADER_DNS_RC"; fi
    return "$CT_SOURCE_DNS_RC"
  }
  _dns_baseline_from secure-apps other >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && [ "$_G_INVALID" -eq 0 ]
}

contract_global_dns_failure_is_invalid() {
  local rc=0
  _G_INVALID=0; _G_INVALID_REASONS=()
  CT_GRADER_DNS_RC=1; CT_SOURCE_DNS_RC=0
  _dns_baseline_from secure-apps other >/dev/null 2>&1 || rc=$?
  CT_GRADER_DNS_RC=0
  [ "$rc" -eq 2 ] && [ "$_G_INVALID" -eq 1 ]
}

check "source-Pod DNS policy failure remains candidate FAIL" \
  contract_source_dns_failure_is_candidate_fail
check "independent grader DNS failure becomes INVALID" \
  contract_global_dns_failure_is_invalid
check "timeout is recognized as network denial" \
  _denial_output_is_blocked 'wget: download timed out'
if _denial_output_is_blocked 'wget: server returned error: HTTP/1.1 403 Forbidden'; then
  fail "HTTP error must not be classified as network denial"
else
  pass "HTTP error is not classified as network denial"
fi
if _denial_output_is_blocked 'error: unable to upgrade connection: pod not found'; then
  fail "kubectl exec error must not be classified as network denial"
else
  pass "kubectl exec error is not classified as network denial"
fi

# http_denied_from의 선행조건을 각각 제어한다. source/target/endpoint 오류는
# '차단 성공'이 아니며, 모든 선행조건 뒤 실제 timeout일 때만 통과해야 한다.
CT_SOURCE_RC=0
CT_BASELINE_RC=0
CT_TARGET_RC=0
CT_SERVICE_RC=0
CT_DENIED_RC=0
_pod_http_source_ready() { return "$CT_SOURCE_RC"; }
_url_host() { printf '%s\n' db-svc.secure-apps.svc.cluster.local; }
_host_uses_dns() { return 0; }
_dns_baseline_from() { return "$CT_BASELINE_RC"; }
_target_resolves_from() { return "$CT_TARGET_RC"; }
_target_service_ready() { return "$CT_SERVICE_RC"; }
_http_actually_denied_from() { return "$CT_DENIED_RC"; }

denied_probe() {
  http_denied_from secure-apps other http://db-svc.secure-apps.svc.cluster.local
}

contract_denied_missing_source_fails() {
  CT_SOURCE_RC=1; CT_TARGET_RC=0; CT_SERVICE_RC=0; CT_DENIED_RC=0
  if denied_probe; then CT_SOURCE_RC=0; return 1; fi
  CT_SOURCE_RC=0
}

contract_denied_unresolved_target_fails() {
  CT_TARGET_RC=1; CT_SERVICE_RC=0; CT_DENIED_RC=0
  if denied_probe; then CT_TARGET_RC=0; return 1; fi
  CT_TARGET_RC=0
}

contract_denied_no_endpoint_fails() {
  CT_TARGET_RC=0; CT_SERVICE_RC=1; CT_DENIED_RC=0
  if denied_probe; then CT_SERVICE_RC=0; return 1; fi
  CT_SERVICE_RC=0
}

contract_denied_http_response_fails() {
  CT_SERVICE_RC=0; CT_DENIED_RC=1
  if denied_probe; then CT_DENIED_RC=0; return 1; fi
  CT_DENIED_RC=0
}

contract_denied_timeout_passes() {
  CT_SOURCE_RC=0; CT_BASELINE_RC=0; CT_TARGET_RC=0; CT_SERVICE_RC=0; CT_DENIED_RC=0
  denied_probe
}

check "missing source Pod is not accepted as denied" contract_denied_missing_source_fails
check "unresolved target is not accepted as denied" contract_denied_unresolved_target_fails
check "Service without ready endpoints is not accepted as denied" contract_denied_no_endpoint_fails
check "HTTP response/connection refusal is not accepted as denied" contract_denied_http_response_fails
check "denial passes only after all control checks" contract_denied_timeout_passes

printf '%s\n' "══ array and relationship contract ══"
CT_JP_OUTPUT=""
CT_JP_RC=0
_jp_get() { printf '%s\n' "$CT_JP_OUTPUT"; return "$CT_JP_RC"; }

contract_array_exact_positive() {
  CT_JP_OUTPUT="get list update"
  jp_array_has role sample ns '{}' get
}

contract_array_substring_negative() {
  CT_JP_OUTPUT="targetPort forget"
  ! jp_array_has role sample ns '{}' get
}

contract_array_count() {
  CT_JP_OUTPUT=$'get list\nwatch'
  jp_array_count role sample ns '{}' 3
}

contract_relation_same_element() {
  CT_JP_OUTPUT=$'Service|web-a|80\nService|web-b|443'
  jp_relation_has ingress sample ns '{}' 'Service|web-b|443'
}

contract_relation_cross_element_rejected() {
  CT_JP_OUTPUT=$'Service|web-a|80\nService|web-b|443'
  ! jp_relation_has ingress sample ns '{}' 'Service|web-a|443'
}

check "array helper matches an exact token" contract_array_exact_positive
check "array helper rejects substring-only match" contract_array_substring_negative
check "array helper counts scalar elements" contract_array_count
check "relationship helper accepts a tuple from one element" contract_relation_same_element
check "relationship helper rejects cross-element field mixing" contract_relation_cross_element_rejected

CT_RESOURCE_JSON=""
CT_GATEWAY_JSON=""
CT_NAMESPACE_JSON=""
_resource_json() {
  case "$1" in
    gateway) printf '%s' "$CT_GATEWAY_JSON" ;;
    namespace) printf '%s' "$CT_NAMESPACE_JSON" ;;
    *) printf '%s' "$CT_RESOURCE_JSON" ;;
  esac
}

contract_gateway_route_canonical_passes() {
  CT_RESOURCE_JSON='{"spec":{"parentRefs":[{"name":"main-gw"}],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/store"}}],"backendRefs":[{"name":"store-svc","port":80}]}]}}'
  gateway_parent_ref_has store-route traffic main-gw http 80 || {
    printf 'gateway parent canonical fixture failed\n' >&2
    return 1
  }
  httproute_rule_has store-route traffic /store store-svc 80 || {
    printf 'HTTPRoute canonical fixture failed\n' >&2
    return 1
  }
}

contract_gateway_wrong_section_rejected() {
  CT_RESOURCE_JSON='{"spec":{"parentRefs":[{"name":"main-gw","sectionName":"https"}]}}'
  ! gateway_parent_ref_has store-route traffic main-gw http 80
}

contract_gateway_zero_weight_rejected() {
  CT_RESOURCE_JSON='{"spec":{"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/store"}}],"backendRefs":[{"name":"store-svc","port":80,"weight":0}]}]}}'
  ! httproute_rule_has store-route traffic /store store-svc 80
}

contract_gateway_extra_match_constraint_rejected() {
  CT_RESOURCE_JSON='{"spec":{"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/store"},"headers":[{"name":"x-debug","value":"yes"}]}],"backendRefs":[{"name":"store-svc","port":80}]}]}}'
  ! httproute_rule_has store-route traffic /store store-svc 80
}

contract_gateway_allowed_routes_default_passes() {
  CT_GATEWAY_JSON='{"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80}]}}'
  CT_NAMESPACE_JSON='{"metadata":{"name":"traffic","labels":{"kubernetes.io/metadata.name":"traffic"}}}'
  gateway_listener_allows_httproute main-gw traffic http traffic
}

contract_gateway_wrong_kind_rejected() {
  CT_GATEWAY_JSON='{"spec":{"listeners":[{"name":"http","allowedRoutes":{"kinds":[{"group":"gateway.networking.k8s.io","kind":"GRPCRoute"}]}}]}}'
  CT_NAMESPACE_JSON='{"metadata":{"name":"traffic","labels":{}}}'
  ! gateway_listener_allows_httproute main-gw traffic http traffic
}

contract_gateway_selector_mismatch_rejected() {
  CT_GATEWAY_JSON='{"spec":{"listeners":[{"name":"http","allowedRoutes":{"namespaces":{"from":"Selector","selector":{"matchLabels":{"route-access":"allowed"}}}}}]}}'
  CT_NAMESPACE_JSON='{"metadata":{"name":"traffic","labels":{"route-access":"denied"}}}'
  ! gateway_listener_allows_httproute main-gw traffic http traffic
}

check "canonical Gateway parent and HTTPRoute rule pass" contract_gateway_route_canonical_passes
check "wrong Gateway listener section is rejected" contract_gateway_wrong_section_rejected
check "zero-weight Gateway backend is rejected" contract_gateway_zero_weight_rejected
check "extra HTTPRoute match constraints are rejected" \
  contract_gateway_extra_match_constraint_rejected
check "default Gateway allowedRoutes accepts a same-namespace HTTPRoute" \
  contract_gateway_allowed_routes_default_passes
check "Gateway allowedRoutes rejects a different Route kind" \
  contract_gateway_wrong_kind_rejected
check "Gateway allowedRoutes rejects a namespace selector mismatch" \
  contract_gateway_selector_mismatch_rejected

contract_nonblank_output_ignores_only_blank_placement() (
  local fixture
  fixture="$(mktemp "${TMPDIR:-/tmp}/cka-contract-output.XXXXXX")" || return 1
  trap 'rm -f -- "$fixture"' EXIT
  printf 'Server: dns\n\nName: service\nAddress: 10.0.0.1\n\n' > "$fixture"
  file_exact_nonblank_command_output "$fixture" \
    printf 'Server: dns\nName: service\nAddress: 10.0.0.1\n\n'
)

contract_nonblank_output_rejects_missing_line() (
  local fixture
  fixture="$(mktemp "${TMPDIR:-/tmp}/cka-contract-output.XXXXXX")" || return 1
  trap 'rm -f -- "$fixture"' EXIT
  printf 'Server: dns\nName: service\n' > "$fixture"
  ! file_exact_nonblank_command_output "$fixture" \
    printf 'Server: dns\nName: service\nAddress: 10.0.0.1\n'
)

check "full-output comparison ignores only blank-line placement" \
  contract_nonblank_output_ignores_only_blank_placement
check "full-output comparison rejects a missing nonblank line" \
  contract_nonblank_output_rejects_missing_line

contract_workdir_rejects_symlink_target() (
  local root victim
  root="$(mktemp -d "${TMPDIR:-/tmp}/cka-workdir-contract.XXXXXX")" || return 1
  case "$root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$root"' EXIT
  victim="$root/victim"
  mkdir -p "$root/work" "$victim"
  printf 'keep\n' > "$victim/evidence"
  ln -s "$victim" "$root/work/ts-01"
  CKA_WORK_DIR="$root/work"
  ! workdir_reset ts-01 >/dev/null 2>&1 \
    && [ "$(cat "$victim/evidence")" = keep ]
)

check "workdir reset rejects symlinks without touching their target" \
  contract_workdir_rejects_symlink_target

contract_state_clear_is_child_bounded() (
  local root victim original_state_dir
  root="$(mktemp -d "${TMPDIR:-/tmp}/cka-state-contract.XXXXXX")" || return 1
  case "$root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$root"' EXIT
  victim="$root/victim"
  mkdir -p "$root/state/status" "$victim"
  printf 'keep\n' > "$victim/evidence"
  ln -s "$victim" "$root/state/exam"
  original_state_dir="$CKA_STATE_DIR"
  CKA_STATE_DIR="$root/state"
  state_subdir_clear status \
    && [ ! -e "$root/state/status" ] \
    && ! state_subdir_clear exam >/dev/null 2>&1 \
    && [ "$(cat "$victim/evidence")" = keep ] \
    && CKA_STATE_DIR=/ \
    && ! state_subdir_clear status >/dev/null 2>&1
  CKA_STATE_DIR="$original_state_dir"
)

check "state cleanup is direct-child bounded and refuses symlinks/root" \
  contract_state_clear_is_child_bounded

contract_cluster_recreate_clears_generation_bound_state() {
  local setup="$CKA_ROOT/cluster/setup-cluster.sh"
  local reset="$CKA_ROOT/cluster/reset-cluster.sh"
  grep -Fq 'for state_child in backup question-data status exam; do' "$setup" \
    && grep -Fq 'state_subdir_clear backup' "$reset" \
    && grep -Fq 'state_subdir_clear question-data' "$reset"
}

check "cluster recreation clears backups and fingerprints from the prior generation" \
  contract_cluster_recreate_clears_generation_bound_state

contract_question_state_clear_rejects_parent_symlink() (
  local root victim
  root="$(mktemp -d "${TMPDIR:-/tmp}/cka-question-state.XXXXXX")" || return 1
  case "$root" in /tmp/*|/var/tmp/*) ;; *) return 1 ;; esac
  trap 'rm -rf -- "$root"' EXIT
  victim="$root/victim"
  mkdir -p "$root/state" "$victim/sn-09"
  printf 'keep\n' > "$victim/sn-09/evidence"
  ln -s "$victim" "$root/state/question-data"
  CKA_STATE_DIR="$root/state"
  ! question_state_clear sn-09 >/dev/null 2>&1 \
    && [ "$(cat "$victim/sn-09/evidence")" = keep ]
)

check "question state cleanup refuses a symlinked parent" \
  contract_question_state_clear_rejects_parent_symlink

printf '%s\n' "══ new-lab semantic contract ══"

contract_ca06_wl07_conflict() (
  export CKA_PLANNER_SOURCE_ONLY=1
  # shellcheck source=../exam/planner.sh
  source "$CKA_ROOT/exam/planner.sh"
  load_catalog
  questions_conflict ca-06 wl-07
)

contract_sn07_teardown_removes_bare_pod() {
  grep -Fq 'cleanup_question sn-07' \
    "$CKA_ROOT/questions/services-networking/sn-07/teardown.sh"
}

check "sn-07 teardown removes its node-pinned bare Pod" \
  contract_sn07_teardown_removes_bare_pod

contract_drain_conflicts_are_complete() (
  export CKA_PLANNER_SOURCE_ONLY=1
  # shellcheck source=../exam/planner.sh
  source "$CKA_ROOT/exam/planner.sh"
  load_catalog
  local drain standalone
  questions_conflict ca-05 ca-06 || return 1
  for drain in ca-05 ca-06; do
    for standalone in sn-03 sn-06 sn-07 sn-10 st-02 st-03 ts-07 ts-08 ts-09; do
      questions_conflict "$drain" "$standalone" || return 1
    done
  done
)

contract_catalog_entry_enabled() { # contract_catalog_entry_enabled <id>
  awk -F '|' -v id="$1" '$1 == id && $7 == "true" { found=1 } END { exit !found }' \
    "$CKA_ROOT/exam/forms/question-catalog.tsv"
}

contract_catalog_entry_disabled() { # contract_catalog_entry_disabled <id>
  awk -F '|' -v id="$1" '$1 == id && $7 == "false" { found=1 } END { exit !found }' \
    "$CKA_ROOT/exam/forms/question-catalog.tsv"
}

contract_disruptive_labs_disabled() {
  contract_catalog_entry_disabled ts-05 \
    && contract_catalog_entry_disabled ts-12 \
    && contract_catalog_entry_disabled ca-06 \
    && contract_catalog_entry_disabled ca-09 \
    && contract_catalog_entry_disabled sn-05 \
    && contract_catalog_entry_disabled ca-11 \
    && contract_catalog_entry_disabled ca-12 \
    && contract_catalog_entry_disabled ca-13 \
    && contract_catalog_entry_disabled st-06
}

contract_wl08_baseline_is_strict() {
  local setup="$CKA_ROOT/questions/workloads-scheduling/wl-08/setup.sh"
  ! grep -Fq 'condition=Available' "$setup" &&
    grep -Fq 'readyReplicas' "$setup" &&
    grep -Fq 'ReplicaFailure' "$setup" &&
    grep -Fq "status.used.requests\\.cpu" "$setup"
}

contract_wl08_rejects_weakened_quota() {
  local grade="$CKA_ROOT/questions/workloads-scheduling/wl-08/grade.sh"
  grep -Fq "'{.spec.scopes}' ''" "$grade" &&
    grep -Fq "'{.spec.scopeSelector}' ''" "$grade" &&
    grep -Fq 'nginx|nginx:1.29|200m|128Mi|400m|256Mi' "$grade"
}

contract_wl07_checks_exact_semantics() {
  local grade="$CKA_ROOT/questions/workloads-scheduling/wl-07/grade.sh"
  grep -Fq 'len(terms) != 1' "$grade" &&
    grep -Fq 'len(expressions) == 1' "$grade" &&
    grep -Fq 'selector_is_exact' "$grade" &&
    grep -Fq '"operator": "In"' "$grade" &&
    grep -Fq 'owned_rs["$rs_uid"]' "$grade"
}

contract_st05_persists_and_checks_uid() {
  local qdir="$CKA_ROOT/questions/storage/st-05"
  grep -Fq 'baseline-pv-uid' "$qdir/setup.sh" &&
    grep -Fq 'current_uid' "$qdir/grade.sh" &&
    grep -Fq 'baseline-pv-uid' "$qdir/teardown.sh" &&
    grep -Fq 'containers[0].get("image") != "busybox:1.36"' "$qdir/grade.sh" &&
    grep -Fq 'archive_mounts[0].get("name") == volume_name' "$qdir/grade.sh"
}

contract_existing_workload_and_network_labs_are_semantic() {
  local wl01="$CKA_ROOT/questions/workloads-scheduling/wl-01"
  local wl03="$CKA_ROOT/questions/workloads-scheduling/wl-03/grade.sh"
  local wl04="$CKA_ROOT/questions/workloads-scheduling/wl-04/grade.sh"
  local sn07="$CKA_ROOT/questions/services-networking/sn-07"
  grep -Fq 'baseline-deployment-uid' "$wl01/setup.sh" \
    && grep -Fq 'wl01_deployment_uid_preserved' "$wl01/grade.sh" \
    && grep -Fq 'delete deploy api-server' "$wl01/near-miss.sh" \
    && grep -Fq 'len(metrics) == 1' "$wl03" \
    && grep -Fq 'ScalingActive=True' "$wl03" \
    && grep -Fq 'container.get("name") == "api"' "$wl04" \
    && grep -Fq 'deployment-fingerprint' "$sn07/setup.sh" \
    && grep -Fq 'sn07_cross_node_http_ok' "$sn07/grade.sh"
}

contract_ts12_waits_for_replacement_and_ready() {
  local qdir="$CKA_ROOT/questions/troubleshooting/ts-12"
  grep -Fq 'scheduler_broken=0' "$qdir/setup.sh" \
    && grep -Fq 'new_pod_uid' "$qdir/setup.sh" \
    && grep -Fq 'pending_baseline=0' "$qdir/setup.sh" \
    && grep -Fq 'old_container_id=' "$qdir/solve.sh" \
    && grep -Fq 'new_container_id' "$qdir/solve.sh" \
    && grep -Fq 'ts12_scheduler_ready' "$qdir/grade.sh" \
    && grep -Fq 'status.conditions[?(@.type=="Ready")].status' "$qdir/teardown.sh"
}

check "planner marks ca-06 and wl-07 incompatible" contract_ca06_wl07_conflict
check "drain labs exclude each other and unmanaged-Pod labs" \
  contract_drain_conflicts_are_complete
check "disruptive and disposable-cell labs stay out of the shared form" \
  contract_disruptive_labs_disabled
check "wl-07 remains enabled after semantic hardening" contract_catalog_entry_enabled wl-07
check "wl-08 remains enabled after semantic hardening" contract_catalog_entry_enabled wl-08
check "st-05 remains enabled after semantic hardening" contract_catalog_entry_enabled st-05
check "wl-08 setup validates the intended failed-admission baseline" contract_wl08_baseline_is_strict
check "wl-08 grader rejects quota scope weakening and checks image" contract_wl08_rejects_weakened_quota
check "wl-07 grader checks exact affinity, selector, and ownership" contract_wl07_checks_exact_semantics
check "st-05 persists PV identity and joins claim/volume/mount" contract_st05_persists_and_checks_uid
check "existing workload/network labs enforce identity and semantic live outcomes" \
  contract_existing_workload_and_network_labs_are_semantic
check "ts-12 waits for a replacement scheduler container to become Ready" \
  contract_ts12_waits_for_replacement_and_ready

contract_addon_repair_failure_propagates() (
  recover_cluster_nodes_ordered() { return 0; }
  require_cluster_readonly() { return 0; }
  ensure_addons() { printf '0'; return 1; }
  ! repair_cluster >/dev/null 2>&1
)

check "addon repair failure propagates to the caller" contract_addon_repair_failure_propagates

contract_addon_image_and_readiness_are_checked() (
  kctx() { printf '%s' '7|7|1|1|1|1|1||registry.example/controller:v1@sha256:abc'; }
  addon_deploy_ready_with_image ns controller 'registry.example/controller:v1@sha256:abc' \
    && ! addon_deploy_ready_with_image ns controller 'registry.example/controller:v2@sha256:abc'
)

contract_cloud_provider_lifecycle_is_fail_closed() {
  local addons="$CKA_ROOT/lib/addons.sh"
  local cli="$CKA_ROOT/cka"
  local reset="$CKA_ROOT/cluster/reset-cluster.sh"
  local sn09="$CKA_ROOT/questions/services-networking/sn-09"
  grep -Fq '${XDG_RUNTIME_DIR:-$HOME/.local/state}/cka-practice' "$addons" \
    && grep -Fq 'exec {lock_fd}< "$CLOUD_PROVIDER_KIND_RUNTIME_DIR"' "$addons" \
    && ! grep -Fq 'lifecycle.lock' "$addons" \
    && grep -Fq '/proc/sys/kernel/random/boot_id' "$addons" \
    && grep -Fq 'cloud_provider_kind_proxy_image_ok || return 1' "$addons" \
    && grep -Fq 'cloud_provider_kind_cluster_proxy_images_ok "$CKA_CLUSTER_NAME" || return 1' "$addons" \
    && grep -Fq "[ \"\$running\" = \"true\" ]" "$addons" \
    && grep -Fq "[ \"\$paused\" = \"false\" ]" "$addons" \
    && grep -Fq "[ \"\$restarting\" = \"false\" ]" "$addons" \
    && grep -Fq '_cloud_provider_kind_untracked_process_exists' "$addons" \
    && grep -Fq '_cloud_provider_kind_other_clusters_exist' "$addons" \
    && grep -Fq 'Caches are synced' "$addons" \
    && grep -Fq 'cloud_provider_kind_cleanup_cluster_loadbalancers' "$cli" \
    && grep -Fq 'cloud_provider_kind_cleanup_cluster_loadbalancers' "$reset" \
    && ! grep -Fq 'cloud_provider_kind_stop' "$reset" \
    && grep -Fq 'sn09-port80-preflight' "$sn09/setup.sh" \
    && grep -Fq 'port: 80' "$sn09/setup.sh" \
    && grep -Fq 'sentinel.sha256' "$sn09/grade.sh" \
    && grep -Fq 'get networkpolicy -o json' "$sn09/setup.sh" \
    && grep -Fq 'get networkpolicy -o json' "$sn09/grade.sh" \
    && grep -Fq 'deny-store-ingress' "$sn09/near-miss-tamper.sh" \
    && grep -Fq 'store-deployment.sha256' "$sn09/grade.sh"
}

contract_etcd_graders_check_real_outputs() {
  local ca03="$CKA_ROOT/questions/cluster-architecture/ca-03/grade.sh"
  local ca04="$CKA_ROOT/questions/cluster-architecture/ca-04/grade.sh"
  local ca04_setup="$CKA_ROOT/questions/cluster-architecture/ca-04/setup.sh"
  grep -Fq 'file_exact_command_output' "$ca03" \
    && grep -Fq 'source-fingerprint' "$ca04_setup" \
    && grep -Fq 'ca04_source_snapshot_unchanged' "$ca04" \
    && grep -Fq 'snapshot status' "$ca04" \
    && grep -Fq 'source.get("revision") == restored.get("revision")' "$ca04" \
    && grep -Fq 'ca04_restored_member_matches_reference' "$ca04" \
    && grep -Fq 'endpoint health' "$ca04" \
    && grep -Fq 'endpoint hashkv' "$ca04" \
    && grep -Fq 'member list' "$ca04" \
    && grep -Fq 'ca04_probe_ports_unused' "$ca04" \
    && grep -Fq 'ca04_probe_process_owns_ports' "$ca04" \
    && grep -Fq '"$source_sha" != "$restored_sha"' "$ca04"
}

contract_runner_lock_and_cleanup_are_bounded() {
  local runner="$CKA_ROOT/exam/mock-exam.sh"
  grep -Fq 'ln "$owner_tmp" "$LOCK_DIR/owner"' "$runner" \
    && grep -Fq 'ln "$gate_tmp" "$LOCK_DIR/acquire-gate"' "$runner" \
    && grep -Fq 'verify_cluster_cleanup_invariants_bounded "$cleanup_deadline"' "$runner" \
    && grep -Fq 'run_bounded "$remaining" env CKA_EXAM_SOURCE_ONLY=0' "$runner"
}

check "addon readiness and locked image are both checked" \
  contract_addon_image_and_readiness_are_checked
check "Cloud Provider KIND lifecycle and sn-09 preflight fail closed" \
  contract_cloud_provider_lifecycle_is_fail_closed
check "etcd backup/restore graders verify real command data" \
  contract_etcd_graders_check_real_outputs
check "exam lock publication is atomic and final cleanup verification is bounded" \
  contract_runner_lock_and_cleanup_are_bounded

contract_etcd_tools_use_running_container_rootfs() {
  grep -Fq 'io.kubernetes.container.name=etcd' "$CKA_ROOT/lib/common.sh" \
    && grep -Fq "{{.info.pid}}" "$CKA_ROOT/lib/common.sh" \
    && grep -Fq '/proc/$container_pid/root/usr/local/bin/etcdutl' "$CKA_ROOT/lib/common.sh" \
    && grep -Fq 'die "etcd·etcdctl·etcdutl 설치 실패' "$CKA_ROOT/cluster/setup-cluster.sh"
}
check "etcd tools are copied from the running container and setup fails closed" \
  contract_etcd_tools_use_running_container_rootfs

printf '%s\n' "══ all-question static contract ══"
STATIC_OK=1
mapfile -t META_FILES < <(find "$CKA_ROOT/questions" -type f -name meta.yaml | sort)
mapfile -t GRADE_FILES < <(find "$CKA_ROOT/questions" -type f -name grade.sh | sort)
if [ "${#GRADE_FILES[@]}" -ne "${#META_FILES[@]}" ]; then
  fail "question/grader count mismatch: ${#META_FILES[@]} meta, ${#GRADE_FILES[@]} grade"
  STATIC_OK=0
fi

for meta_file in "${META_FILES[@]}"; do
  qdir="$(dirname "$meta_file")"
  qid="$(basename "$qdir")"
  for required in question.md setup.sh grade.sh solve.sh answer.md; do
    [ -f "$qdir/$required" ] \
      || { fail "$qid: $required missing"; STATIC_OK=0; }
  done
  [ "$(meta_get "$qdir" id)" = "$qid" ] \
    || { fail "$qid: meta id mismatch"; STATIC_OK=0; }
  bash -n "$qdir/setup.sh" >/dev/null 2>&1 \
    || { fail "$qid: setup.sh syntax"; STATIC_OK=0; }
  bash -n "$qdir/solve.sh" >/dev/null 2>&1 \
    || { fail "$qid: solve.sh syntax"; STATIC_OK=0; }
  if [ -f "$qdir/teardown.sh" ]; then
    bash -n "$qdir/teardown.sh" >/dev/null 2>&1 \
      || { fail "$qid: teardown.sh syntax"; STATIC_OK=0; }
  fi
done

for grade_file in "${GRADE_FILES[@]}"; do
  qid="$(basename "$(dirname "$grade_file")")"
  [ -f "$(dirname "$grade_file")/meta.yaml" ] \
    || { fail "$qid: meta.yaml missing"; STATIC_OK=0; }
  bash -n "$grade_file" >/dev/null 2>&1 || { fail "$qid: grade.sh syntax"; STATIC_OK=0; }
  grep -Fq 'lib/grader.sh' "$grade_file" || { fail "$qid: grader library not sourced"; STATIC_OK=0; }
  grep -Eq "^[[:space:]]*grade_init[[:space:]]+['\"]?${qid}(['\"]?)([[:space:]]|$)" "$grade_file" \
    || { fail "$qid: grade_init id mismatch"; STATIC_OK=0; }
  grep -Eq '^[[:space:]]*criterion[[:space:]]+[0-9]+' "$grade_file" \
    || { fail "$qid: no criterion"; STATIC_OK=0; }
  grep -Eq '^[[:space:]]*grade_finish([[:space:]]|$)' "$grade_file" \
    || { fail "$qid: no grade_finish"; STATIC_OK=0; }
  if grep -Eq 'require_cluster|ensure_addons|addon_install_' "$grade_file"; then
    fail "$qid: grader may mutate/repair infrastructure"
    STATIC_OK=0
  fi
  if grep -Eq '![[:space:]]*http_(ok|ok_from)' "$grade_file"; then
    fail "$qid: raw negated HTTP probe can false-positive"
    STATIC_OK=0
  fi
  meta_points="$(meta_get "$(dirname "$grade_file")" points)"
  criterion_points="$(awk '/^[[:space:]]*criterion[[:space:]]+[0-9]+/ {sum += $2} END {print sum+0}' "$grade_file")"
  [ "$meta_points" = "$criterion_points" ] \
    || { fail "$qid: meta points $meta_points != criteria $criterion_points"; STATIC_OK=0; }
done

[ "$STATIC_OK" -eq 1 ] && pass "${#GRADE_FILES[@]} graders satisfy the static contract"

printf '\n%s\n' "contract-test: pass $PASS_COUNT / fail $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '%s\n' "failed: ${FAILED[*]}"
  exit 1
fi
