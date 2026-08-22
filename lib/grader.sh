#!/usr/bin/env bash
# 채점 러너 — 각 문제의 grade.sh에서 source 한다.
#
# 사용법:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
#   grade_init "st-01"
#   criterion 2 "PVC app-data가 존재" "res_exists pvc app-data project-alpha"
#   criterion 3 "PVC가 Bound 상태"   "jp_eq pvc app-data project-alpha '{.status.phase}' Bound"
#   grade_finish
#
# 채점 원칙 (docs/grading-policy.md 참조):
#  - 요구사항을 검증 항목(criterion)으로 분해하고 항목별로 부분 점수를 준다.
#  - 검증은 라이브 클러스터 상태(또는 제출 파일)를 기준으로 한다.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_G_EARNED=0
_G_MAX=0
_G_ID=""
_G_RESULT=""
_G_INVALID=0
declare -a _G_INVALID_REASONS=()

# 채점 불능 상태를 후보자의 오답과 구분한다. helper 안에서 호출해도
# criterion이 최종적으로 INVALID를 우선하도록 전역 플래그를 함께 남긴다.
grade_invalid() { # grade_invalid <reason>
  local reason="${1:-unknown infrastructure error}" seen
  _G_INVALID=1
  for seen in "${_G_INVALID_REASONS[@]}"; do
    [ "$seen" = "$reason" ] && return 2
  done
  _G_INVALID_REASONS+=("$reason")
  return 2
}

grade_init() {
  _G_ID="$1"; _G_EARNED=0; _G_MAX=0; _G_RESULT=""
  _G_INVALID=0; _G_INVALID_REASONS=()
  printf '\n%s\n' "${C_BLD}── Grading $_G_ID ────────────────────────────────────────────${C_RST}"

  # require_cluster는 누락된 애드온을 자동 설치한다. 채점 중 복구하면 후보자의
  # 결과와 랩 장애가 섞이므로, 여기서는 현재 API 상태만 읽어서 판정한다.
  if ! command -v kubectl >/dev/null 2>&1; then
    grade_invalid "kubectl unavailable" || true
  elif ! cluster_ready; then
    grade_invalid "cluster API unavailable or context missing: $CKA_CONTEXT" || true
  fi
  return 0
}

criterion() { # criterion <배점> <설명> <검증 커맨드 문자열>
  local pts="$1" desc="$2" cmd="$3" rc=0
  _G_MAX=$((_G_MAX + pts))
  if [ "$_G_INVALID" -ne 0 ]; then
    printf ' %s %-60s (%s)\n' "${C_YLW}!${C_RST}" "$desc" "INVALID"
    return 0
  fi

  eval "$cmd" >/dev/null 2>&1 || rc=$?
  # helper가 인프라 결함을 발견했다면 명령의 shell status보다 INVALID가 우선한다.
  if [ "$_G_INVALID" -ne 0 ]; then
    printf ' %s %-60s (%s)\n' "${C_YLW}!${C_RST}" "$desc" "INVALID"
  elif [ "$rc" -eq 0 ]; then
    _G_EARNED=$((_G_EARNED + pts))
    printf ' %s %-60s (%d/%d)\n' "${C_GRN}✓${C_RST}" "$desc" "$pts" "$pts"
  else
    printf ' %s %-60s (0/%d)\n' "${C_RED}✗${C_RST}" "$desc" "$pts"
  fi
}

grade_finish() {
  local pct=0 reason=""
  [ "$_G_MAX" -gt 0 ] && pct=$(( _G_EARNED * 100 / _G_MAX ))
  printf '%s\n' " ─────────────────────────────────────────────────────────────"
  if [ "$_G_INVALID" -ne 0 ]; then
    reason="$(IFS='; '; printf '%s' "${_G_INVALID_REASONS[*]}")"
    _G_RESULT="INVALID"
    printf ' %s\n\n' "${C_YLW}${C_BLD}Result: INVALID — ${reason}${C_RST}"
    state_set "$_G_ID" "invalid:${reason}"
    return 2
  elif [ "$_G_EARNED" -eq "$_G_MAX" ]; then
    _G_RESULT="PASS"
    printf ' %s\n\n' "${C_GRN}${C_BLD}Score: $_G_EARNED/$_G_MAX (100%) — 만점${C_RST}"
  else
    _G_RESULT="FAIL"
    printf ' %s\n\n' "${C_BLD}Score: $_G_EARNED/$_G_MAX (${pct}%)${C_RST}"
  fi
  state_set "$_G_ID" "graded:${_G_EARNED}/${_G_MAX}"
  [ "$_G_EARNED" -eq "$_G_MAX" ]
}

# ── 검증 헬퍼 ────────────────────────────────────────────────────
# 네임스페이스 인자에 "-" 를 주면 cluster-scoped 리소스로 취급한다.

res_exists() { # res_exists <kind> <name> [ns]
  if [ -n "${3:-}" ] && [ "${3:-}" != "-" ]; then
    kctx get "$1" "$2" -n "$3" -o name >/dev/null 2>&1
  else
    kctx get "$1" "$2" -o name >/dev/null 2>&1
  fi
}

_jp_get() { # _jp_get <kind> <name> <ns|-> <jsonpath>
  if [ "$3" != "-" ]; then
    kctx get "$1" "$2" -n "$3" -o jsonpath="$4" 2>/dev/null
  else
    kctx get "$1" "$2" -o jsonpath="$4" 2>/dev/null
  fi
}

jp_eq()       { [ "$(_jp_get "$1" "$2" "$3" "$4")" = "$5" ]; }
jp_contains() { _jp_get "$1" "$2" "$3" "$4" | grep -q -- "$5"; }

# JSONPath 배열의 공백 없는 scalar 원소를 substring이 아닌 exact token으로 비교한다.
# 기존 jp_contains는 object fragment 검사 호환성 때문에 유지하되, 신규 배열 검증은
# jp_array_has를 사용한다.
jp_array_has() { # jp_array_has <kind> <name> <ns|-> <jsonpath> <expected-token>
  local out
  out="$(_jp_get "$1" "$2" "$3" "$4")" || return 1
  printf '%s\n' "$out" | tr '[:space:]' '\n' | grep -Fxq -- "$5"
}

jp_array_count() { # jp_array_count <kind> <name> <ns|-> <jsonpath> <count>
  local out count
  out="$(_jp_get "$1" "$2" "$3" "$4")" || return 1
  count="$(printf '%s\n' "$out" | tr '[:space:]' '\n' | grep -cve '^$')"
  [ "$count" -eq "$5" ]
}

# 호출자가 {range ...}{.fieldA}{"|"}{.fieldB}{"\n"}{end} 형태로 만든
# 한 줄짜리 tuple을 exact match한다. 서로 다른 배열 원소의 필드를 조합하는
# 관계 오탐을 피하기 위한 helper다.
jp_relation_has() { # jp_relation_has <kind> <name> <ns|-> <jsonpath> <expected-line>
  _jp_get "$1" "$2" "$3" "$4" | grep -Fxq -- "$5"
}

deploy_ready() { # deploy_ready <ns> <name> <ready-replicas>
  local status generation observed desired current updated ready available expected="$3"
  status="$(kctx -n "$1" get deploy "$2" \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.spec.replicas}{"|"}{.status.replicas}{"|"}{.status.updatedReplicas}{"|"}{.status.readyReplicas}{"|"}{.status.availableReplicas}' \
    2>/dev/null)" || return 1
  IFS='|' read -r generation observed desired current updated ready available <<< "$status"

  # readyReplicas 하나만 보면 이전 ReplicaSet의 Ready Pod나 관찰되지 않은 새 spec도
  # 통과할 수 있다. controller가 현재 generation을 관찰했고 모든 replica 계수가
  # 원하는 값으로 수렴한 경우에만 rollout 완료로 취급한다.
  [ -n "$generation" ] && [ "$observed" = "$generation" ] && \
    [ "${desired:-1}" = "$expected" ] && \
    [ "${current:-0}" = "$expected" ] && \
    [ "${updated:-0}" = "$expected" ] && \
    [ "${ready:-0}" = "$expected" ] && \
    [ "${available:-0}" = "$expected" ]
}

_template_spec_path() { # _template_spec_path <kind>
  case "${1,,}" in
    pod|pods) printf '%s\n' '.spec' ;;
    deploy|deployment|deployments|statefulset|statefulsets|daemonset|daemonsets)
      printf '%s\n' '.spec.template.spec'
      ;;
    *) return 1 ;;
  esac
}

_safe_container_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

volume_mounted_at() { # volume_mounted_at <kind> <name> <ns|-> <volume> <path> [container]
  local root mounts jp container="${6:-}"
  root="$(_template_spec_path "$1")" || return 1
  if [ -n "$container" ]; then
    _safe_container_name "$container" || return 1
    jp="{range ${root}.containers[?(@.name==\"${container}\")].volumeMounts[*]}{.name}{\"|\"}{.mountPath}{\"\\n\"}{end}"
  else
    jp="{range ${root}.containers[*].volumeMounts[*]}{.name}{\"|\"}{.mountPath}{\"\\n\"}{end}"
  fi
  mounts="$(_jp_get "$1" "$2" "$3" "$jp")" || return 1
  printf '%s\n' "$mounts" | grep -Fxq -- "$4|$5"
}

# PVC claimName을 가진 volume의 이름과 실제 volumeMount의 name/path를 연결해
# 검사한다. claimName과 mountPath를 서로 다른 volume에서 골라 합치는 오탐을 막는다.
claim_mounted_at() { # claim_mounted_at <kind> <name> <ns|-> <claim> <path> [container]
  local root volumes volume_name claim_name
  root="$(_template_spec_path "$1")" || return 1
  volumes="$(_jp_get "$1" "$2" "$3" \
    "{range ${root}.volumes[*]}{.name}{\"|\"}{.persistentVolumeClaim.claimName}{\"\\n\"}{end}")" \
    || return 1
  while IFS='|' read -r volume_name claim_name; do
    [ -n "$volume_name" ] && [ "$claim_name" = "$4" ] || continue
    volume_mounted_at "$1" "$2" "$3" "$volume_name" "$5" "${6:-}" && return 0
  done <<< "$volumes"
  return 1
}

emptydir_mounted_at() { # emptydir_mounted_at <kind> <name> <ns|-> <volume> <path> [container]
  local json
  _python3_require || return $?
  json="$(_resource_json "$1" "$2" "$3")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
kind, volume_name, mount_path, container_name = sys.argv[1:5]
if kind.lower() in {"pod", "pods"}:
    spec = obj.get("spec", {})
else:
    spec = obj.get("spec", {}).get("template", {}).get("spec", {})
volume_ok = any(
    volume.get("name") == volume_name and "emptyDir" in volume
    for volume in spec.get("volumes", [])
)
mount_ok = any(
    (not container_name or container.get("name") == container_name)
    and any(
        mount.get("name") == volume_name and mount.get("mountPath") == mount_path
        for mount in container.get("volumeMounts", [])
    )
    for container in spec.get("containers", [])
)
raise SystemExit(0 if volume_ok and mount_ok else 1)
' "$1" "$4" "$5" "${6:-}"
}

container_argv_has() { # container_argv_has <kind> <name> <ns|-> <container> <exact-token>
  local root command args
  _safe_container_name "$4" || return 1
  root="$(_template_spec_path "$1")" || return 1
  command="$(_jp_get "$1" "$2" "$3" \
    "{${root}.containers[?(@.name==\"$4\")].command[*]}")" || return 1
  args="$(_jp_get "$1" "$2" "$3" \
    "{${root}.containers[?(@.name==\"$4\")].args[*]}")" || return 1
  printf '%s\n%s\n' "$command" "$args" | tr '[:space:]' '\n' | grep -Fxq -- "$5"
}

_python3_require() {
  command -v python3 >/dev/null 2>&1 && return 0
  grade_invalid "grading dependency unavailable: python3" || true
  return 2
}

_resource_json() { # _resource_json <kind> <name> <ns|->
  if [ "$3" = "-" ]; then
    kctx get "$1" "$2" -o json 2>/dev/null
  else
    kctx -n "$3" get "$1" "$2" -o json 2>/dev/null
  fi
}

# command와 args를 합친 실제 argv 기준으로 컨테이너를 찾는다. 같은 프로세스를
# command=[sleep,infinity] 또는 command=[sleep],args=[infinity]로 표현한 답을
# 모두 허용하면서 컨테이너 이름(선택)과 이미지는 정확히 검증한다.
container_process_is() { # <kind> <name> <ns|-> <container|-> <image> <argv...>
  local json
  _python3_require || return $?
  json="$(_resource_json "$1" "$2" "$3")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
kind, container_name, image = sys.argv[1:4]
expected = sys.argv[4:]
if kind.lower() in {"pod", "pods"}:
    spec = obj.get("spec", {})
else:
    spec = obj.get("spec", {}).get("template", {}).get("spec", {})
ok = any(
    (container_name == "-" or c.get("name") == container_name)
    and c.get("image") == image
    and c.get("command", []) + c.get("args", []) == expected
    for c in spec.get("containers", [])
)
raise SystemExit(0 if ok else 1)
' "$1" "$4" "$5" "${@:6}"
}

# rule 배열 순서와 rule 분할 방식에 관계없이, 한 rule이 실제로 허용하는
# apiGroup/resource/verb 조합을 JSON 의미 기준으로 검사한다.
rbac_rule_has() { # rbac_rule_has <kind> <name> <ns|-> <api-group> <resource> <verb>
  local json
  _python3_require || return $?
  json="$(_resource_json "$1" "$2" "$3")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
group, resource, verb = sys.argv[1:4]
ok = any(
    group in rule.get("apiGroups", [])
    and resource in rule.get("resources", [])
    and verb in rule.get("verbs", [])
    for rule in obj.get("rules", [])
)
raise SystemExit(0 if ok else 1)
' "$4" "$5" "$6"
}

# Gateway API ParentReference의 생략 가능한 기본값(group/kind/namespace)을
# 정규화해 명시형과 축약형을 모두 같은 의미로 받아들인다.
gateway_parent_ref_has() { # <route> <ns> <gateway> <listener> <port>
  local json
  _python3_require || return $?
  json="$(_resource_json httproute "$1" "$2")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
namespace, name, listener, port_text = sys.argv[1:5]
port = int(port_text)
refs = obj.get("spec", {}).get("parentRefs", [])
ok = len(refs) == 1
if ok:
    ref = refs[0]
    ok = (
        ref.get("name") == name
        and ref.get("group", "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
        and ref.get("kind", "Gateway") == "Gateway"
        and ref.get("namespace", namespace) == namespace
        and ref.get("sectionName", listener) == listener
        and ref.get("port", port) == port
    )
raise SystemExit(0 if ok else 1)
' "$2" "$3" "$4" "$5"
}

# Gateway listener의 AllowedRoutes를 실제 route namespace label까지 포함해
# 평가한다. allowedRoutes/kinds 생략 또는 빈 배열은 HTTP listener가 지원하는
# HTTPRoute를 허용하며, namespaces.from 생략은 Same으로 정규화한다.
gateway_listener_allows_httproute() { # <gateway> <gateway-ns> <listener> <route-ns>
  local gateway_json namespace_json
  _python3_require || return $?
  gateway_json="$(_resource_json gateway "$1" "$2")" || return 1
  namespace_json="$(_resource_json namespace "$4" -)" || return 1
  python3 -c '
import json, sys

gateway = json.loads(sys.argv[1])
namespace = json.loads(sys.argv[2])
gateway_ns, listener_name, route_ns = sys.argv[3:6]
listeners = [
    item for item in gateway.get("spec", {}).get("listeners", [])
    if item.get("name") == listener_name
]
ok = len(listeners) == 1 and namespace.get("metadata", {}).get("name") == route_ns

def selector_matches(selector, labels):
    if not isinstance(selector, dict):
        return False
    if any(labels.get(key) != value for key, value in selector.get("matchLabels", {}).items()):
        return False
    for expr in selector.get("matchExpressions", []):
        key = expr.get("key")
        op = expr.get("operator")
        values = expr.get("values", [])
        if not isinstance(key, str) or not key:
            return False
        if op == "In":
            matched = key in labels and labels[key] in values
        elif op == "NotIn":
            matched = key not in labels or labels[key] not in values
        elif op == "Exists":
            matched = key in labels and not values
        elif op == "DoesNotExist":
            matched = key not in labels and not values
        else:
            return False
        if not matched:
            return False
    return True

if ok:
    listener = listeners[0]
    allowed = listener.get("allowedRoutes", {})
    kinds = allowed.get("kinds", [])
    kinds_ok = not kinds or any(
        item.get("kind") == "HTTPRoute"
        and item.get("group", "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
        for item in kinds
    )
    namespaces = allowed.get("namespaces", {})
    source = namespaces.get("from", "Same")
    if source == "All":
        namespace_ok = True
    elif source == "Same":
        namespace_ok = gateway_ns == route_ns
    elif source == "Selector":
        namespace_ok = selector_matches(
            namespaces.get("selector"),
            namespace.get("metadata", {}).get("labels", {}),
        )
    else:
        namespace_ok = False
    ok = kinds_ok and namespace_ok

raise SystemExit(0 if ok else 1)
' "$gateway_json" "$namespace_json" "$2" "$3" "$4"
}

# path match와 backend가 같은 HTTPRoute rule 안에 있는지 검사한다. Service와
# PathPrefix의 API 기본값을 명시한 답과 생략한 답을 모두 허용한다.
httproute_rule_has() { # httproute_rule_has <route> <ns> <path> <service> <port>
  local json
  _python3_require || return $?
  json="$(_resource_json httproute "$1" "$2")" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
namespace, path_value, service, port_text = sys.argv[1:5]
port = int(port_text)
rules = obj.get("spec", {}).get("rules", [])
ok = len(rules) == 1
if ok:
    rule = rules[0]
    matches = rule.get("matches", [])
    backends = rule.get("backendRefs", [])
    ok = (
        set(rule).issubset({"matches", "backendRefs"})
        and len(matches) == 1
        and set(matches[0]) == {"path"}
        and matches[0].get("path", {}).get("type", "PathPrefix") == "PathPrefix"
        and matches[0].get("path", {}).get("value") == path_value
        and len(backends) == 1
    )
if ok:
    ref = backends[0]
    ok = (
        ref.get("name") == service
        and ref.get("group", "") == ""
        and ref.get("kind", "Service") == "Service"
        and ref.get("namespace", namespace) == namespace
        and ref.get("port") == port
        and ref.get("weight", 1) > 0
        and not ref.get("filters", [])
    )
raise SystemExit(0 if ok else 1)
' "$2" "$3" "$4" "$5"
}

pod_running() { # pod_running <ns> <pod>
  [ "$(kctx -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]
}

pod_ready() { # pod_ready <ns> <pod>
  [ "$(kctx -n "$1" get pod "$2" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

pods_running_sel() { # pods_running_sel <ns> <selector> <min-count>
  [ "$(kctx -n "$1" get pods -l "$2" --field-selector=status.phase=Running \
      -o name 2>/dev/null | wc -l)" -ge "$3" ]
}

can_i() { # can_i <verb> <resource> <ns> <as> (예: system:serviceaccount:ns:name)
  [ "$(kctx auth can-i "$1" "$2" -n "$3" --as "$4" 2>/dev/null)" = "yes" ]
}

cannot_i() { # 권한이 없어야 통과
  [ "$(kctx auth can-i "$1" "$2" -n "$3" --as "$4" 2>/dev/null)" = "no" ]
}

svc_has_endpoints() { # svc_has_endpoints <ns> <svc>
  local lines ready addresses
  res_exists svc "$2" "$1" || return 1
  lines="$(kctx -n "$1" get endpointslices -l "kubernetes.io/service-name=$2" \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"|"}{.addresses[*]}{"\n"}{end}' \
    2>/dev/null)" || return 1
  while IFS='|' read -r ready addresses; do
    case "$ready" in
      ''|true) [ -n "$addresses" ] && return 0 ;;
    esac
  done <<< "$lines"
  return 1
}

# ── DNS/HTTP 실측 검증 ──────────────────────────────────────────

_url_host() { # _url_host <url>
  local authority="${1#*://}"
  authority="${authority%%/*}"; authority="${authority##*@}"
  case "$authority" in
    \[*\]*) authority="${authority#\[}"; authority="${authority%%\]*}" ;;
    *) authority="${authority%%:*}" ;;
  esac
  printf '%s\n' "$authority"
}

_host_uses_dns() {
  [ -n "$1" ] || return 0
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
  [[ "$1" == *:* ]] && return 1 # bracket를 제거한 IPv6 literal
  return 0
}

_service_ref_from_url() { # full service DNS면 "namespace service" 출력
  local host svc ns marker
  host="$(_url_host "$1")" || return 1
  IFS='.' read -r svc ns marker _ <<< "$host"
  [ -n "$svc" ] && [ -n "$ns" ] && [ "$marker" = "svc" ] || return 1
  printf '%s %s\n' "$ns" "$svc"
}

_grader_client_require() {
  local ready
  ready="$(kctx -n cka-system get deploy grader-client \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || {
      grade_invalid "grading infrastructure missing: cka-system/grader-client"
      return 2
    }
  [ "${ready:-0}" -ge 1 ] && \
    kctx -n cka-system exec deploy/grader-client -- sh -c \
      'command -v wget >/dev/null && command -v nslookup >/dev/null' >/dev/null 2>&1 || {
        grade_invalid "grading infrastructure unavailable: cka-system/grader-client"
        return 2
      }
}

_pod_http_source_ready() { # 문제 리소스이므로 없거나 실행 불능이면 일반 FAIL
  pod_running "$1" "$2" && \
    kctx -n "$1" exec "$2" -- sh -c \
      'command -v wget >/dev/null && command -v nslookup >/dev/null' >/dev/null 2>&1
}

_dns_baseline_grader() {
  kctx -n cka-system exec deploy/grader-client -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 || {
      grade_invalid "cluster DNS unavailable for HTTP grading"
      return 2
    }
}

_dns_baseline_from() {
  _grader_client_require || return $?
  _dns_baseline_grader || return $?
  kctx -n "$1" exec "$2" -- nslookup kubernetes.default.svc.cluster.local \
    >/dev/null 2>&1
}

_target_resolves_grader() {
  local host
  host="$(_url_host "$1")" || return 1
  _host_uses_dns "$host" || return 0
  kctx -n cka-system exec deploy/grader-client -- nslookup "$host" >/dev/null 2>&1
}

_target_resolves_from() {
  local host
  host="$(_url_host "$3")" || return 1
  _host_uses_dns "$host" || return 0
  kctx -n "$1" exec "$2" -- nslookup "$host" >/dev/null 2>&1
}

_target_service_ready() {
  local ref ns svc
  ref="$(_service_ref_from_url "$1")" || return 0
  read -r ns svc <<< "$ref"
  svc_has_endpoints "$ns" "$svc"
}

_http_exec_grader() {
  kctx -n cka-system exec deploy/grader-client -- \
    wget -q -O /dev/null -T 4 "$1" >/dev/null 2>&1
}

_http_exec_from() {
  kctx -n "$1" exec "$2" -- wget -q -O /dev/null -T 4 "$3" >/dev/null 2>&1
}

# HTTP 응답·connection refused·kubectl exec 실패 같은 임의 오류를 차단 성공으로
# 뒤집지 않는다. 네트워크 계층에서 차단됐음을 나타내는 오류만 허용한다.
_denial_output_is_blocked() {
  printf '%s\n' "$1" | grep -Eqi \
    'timed out|network is unreachable|no route to host'
}

_http_actually_denied_grader() {
  local out rc=0
  out="$(kctx -n cka-system exec deploy/grader-client -- \
    wget -S -O /dev/null -T 4 "$1" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  _denial_output_is_blocked "$out"
}

_http_actually_denied_from() {
  local out rc=0
  out="$(kctx -n "$1" exec "$2" -- wget -S -O /dev/null -T 4 "$3" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  _denial_output_is_blocked "$out"
}

# 클러스터 내부에서 HTTP 접근 검증 (cka-system의 상주 grader-client 파드 이용)
http_ok() { # http_ok <url>
  local host
  _grader_client_require || return $?
  host="$(_url_host "$1")" || return 1
  if _host_uses_dns "$host"; then
    _dns_baseline_grader || return $?
    _target_resolves_grader "$1" || return 1
  fi
  _http_exec_grader "$1"
}

http_body_contains() { # http_body_contains <url> <pattern>
  local host
  _grader_client_require || return $?
  host="$(_url_host "$1")" || return 1
  if _host_uses_dns "$host"; then
    _dns_baseline_grader || return $?
    _target_resolves_grader "$1" || return 1
  fi
  kctx -n cka-system exec deploy/grader-client -- wget -q -O - -T 4 "$1" \
    2>/dev/null | grep -q -- "$2"
}

http_denied() { # 접근이 차단되어야 통과 (NetworkPolicy 등)
  local host
  _grader_client_require || return $?
  host="$(_url_host "$1")" || return 1
  if _host_uses_dns "$host"; then
    _dns_baseline_grader || return $?
    _target_resolves_grader "$1" || return 1
  fi
  _target_service_ready "$1" || return 1
  _http_actually_denied_grader "$1"
}

# 특정 파드 안에서 HTTP 접근 검증 (NetworkPolicy 검증용)
http_ok_from() { # http_ok_from <ns> <pod> <url>
  local host
  _pod_http_source_ready "$1" "$2" || return 1
  host="$(_url_host "$3")" || return 1
  if _host_uses_dns "$host"; then
    _dns_baseline_from "$1" "$2" || return $?
    _target_resolves_from "$1" "$2" "$3" || return 1
  fi
  _http_exec_from "$1" "$2" "$3"
}

http_denied_from() {
  local host
  _pod_http_source_ready "$1" "$2" || return 1
  host="$(_url_host "$3")" || return 1
  if _host_uses_dns "$host"; then
    _dns_baseline_from "$1" "$2" || return $?
    _target_resolves_from "$1" "$2" "$3" || return 1
  fi
  _target_service_ready "$3" || return 1
  _http_actually_denied_from "$1" "$2" "$3"
}

# 호스트(WSL)에서 ingress-nginx 경유 접근 검증: kind 포트매핑 80→8080
ingress_ok() { # ingress_ok <host-header> <path> [pattern]
  local body
  body="$(curl -s -m 5 -H "Host: $1" "http://localhost:8080$2" 2>/dev/null)" || return 1
  if [ -n "${3:-}" ]; then printf '%s' "$body" | grep -q -- "$3"; else [ -n "$body" ]; fi
}

dns_resolves() { # dns_resolves <fqdn>
  _grader_client_require || return $?
  # nslookup 실패 출력에도 DNS 서버의 "Address" 행은 나타날 수 있다. 문자열이
  # 아니라 nslookup 자체의 종료 상태를 사용해야 NXDOMAIN/SERVFAIL을 통과시키지 않는다.
  kctx -n cka-system exec deploy/grader-client -- nslookup "$1" >/dev/null 2>&1
}

file_exists() { [ -s "$1" ]; }
file_contains() { grep -Eq -- "$2" "$1" 2>/dev/null; }

# 제출 파일이 지정한 명령의 stdout과 byte 단위로 같은지 검사한다. 단순 grep은
# 필요한 문자열만 베껴 넣거나 일부 출력을 누락한 파일도 통과시키므로 "full command
# output" 요구사항에는 이 helper를 사용한다.
file_exact_command_output() { # file_exact_command_output <file> <command> [args...]
  local file="$1" tmp rc=0
  shift
  [ -f "$file" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/cka-grade.XXXXXX")" || {
    grade_invalid "unable to create grading temporary file" || true
    return 2
  }
  "$@" >"$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && cmp -s -- "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# BusyBox nslookup은 동일한 성공 응답에서도 빈 줄을 answer 앞/뒤에 번갈아 출력할
# 수 있다. 비어 있지 않은 stdout 행은 순서·내용 그대로 모두 비교하되, 빈 줄 위치만
# 정규화한다.
file_exact_nonblank_command_output() { # <file> <command> [args...]
  local file="$1" actual expected rc=0
  shift
  [ -f "$file" ] || return 1
  actual="$(mktemp "${TMPDIR:-/tmp}/cka-grade.actual.XXXXXX")" || {
    grade_invalid "unable to create grading temporary file" || true
    return 2
  }
  expected="$(mktemp "${TMPDIR:-/tmp}/cka-grade.expected.XXXXXX")" || {
    rm -f -- "$actual"
    grade_invalid "unable to create grading temporary file" || true
    return 2
  }
  "$@" 2>/dev/null | grep -v '^[[:space:]]*$' >"$actual"
  [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
  grep -v '^[[:space:]]*$' "$file" >"$expected" || rc=1
  if [ "$rc" -eq 0 ] && [ -s "$actual" ] && cmp -s -- "$expected" "$actual"; then
    rm -f -- "$actual" "$expected"
    return 0
  fi
  rm -f -- "$actual" "$expected"
  return 1
}

file_exact_filtered_command_output() { # <file> <fixed-pattern> <command> [args...]
  local file="$1" pattern="$2" tmp command_rc grep_rc
  local -a pipeline_rc
  shift 2
  [ -f "$file" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/cka-grade.XXXXXX")" || {
    grade_invalid "unable to create grading temporary file" || true
    return 2
  }
  "$@" 2>/dev/null | grep -F -- "$pattern" >"$tmp"
  pipeline_rc=("${PIPESTATUS[@]}")
  command_rc="${pipeline_rc[0]}"; grep_rc="${pipeline_rc[1]}"
  if [ "$command_rc" -eq 0 ] && [ "$grep_rc" -eq 0 ] && cmp -s -- "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# 노드(kind 컨테이너) 안에서 커맨드 실행
node_exec() { docker exec "$1" sh -c "$2" >/dev/null 2>&1; }
node_exec_out() { docker exec "$1" sh -c "$2" 2>/dev/null; }

# 노드에 DaemonSet 관리 외의 Pod가 없으면 성공 (drain 검증)
node_drained() { # node_drained <node>
  local owners
  owners="$(kctx get pods -A --field-selector "spec.nodeName=$1" \
      -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' \
      2>/dev/null)" || return 1
  ! printf '%s\n' "$owners" | grep -v '^$' | grep -qv '^DaemonSet$'
}

node_ready() { # node_ready <node>
  [ "$(kctx get node "$1" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

node_schedulable() { # node_schedulable <node> — cordon 해제 상태면 성공
  res_exists node "$1" && \
  [ "$(kctx get node "$1" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != "true" ]
}

# 라벨에 매칭되는 리소스가 하나도 없으면 성공 (삭제·evict 검증)
res_absent_sel() { # res_absent_sel <kind> <ns|-> <selector>
  local out
  if [ "$2" != "-" ]; then
    res_exists namespace "$2" || return 1
    out="$(kctx -n "$2" get "$1" -l "$3" -o name 2>/dev/null)" || return 1
  else
    out="$(kctx get "$1" -l "$3" -o name 2>/dev/null)" || return 1
  fi
  [ -z "$out" ]
}

# 노드에 설치된 데비안 패키지 버전 검증
node_pkg_version() { # node_pkg_version <node> <pkg> <version>
  [ "$(node_exec_out "$1" "dpkg-query -W -f='\${Version}' $2")" = "$3" ]
}

node_pkg_held() { # node_pkg_held <node> <pkg...>
  local node="$1" held pkg
  shift
  held="$(node_exec_out "$node" 'apt-mark showhold')"
  for pkg in "$@"; do
    printf '%s\n' "$held" | grep -qx "$pkg" || return 1
  done
}
