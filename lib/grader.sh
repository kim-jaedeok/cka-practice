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

grade_init() {
  _G_ID="$1"; _G_EARNED=0; _G_MAX=0
  require_cluster
  printf '\n%s\n' "${C_BLD}── Grading $_G_ID ────────────────────────────────────────────${C_RST}"
}

criterion() { # criterion <배점> <설명> <검증 커맨드 문자열>
  local pts="$1" desc="$2" cmd="$3"
  _G_MAX=$((_G_MAX + pts))
  if eval "$cmd" >/dev/null 2>&1; then
    _G_EARNED=$((_G_EARNED + pts))
    printf ' %s %-60s (%d/%d)\n' "${C_GRN}✓${C_RST}" "$desc" "$pts" "$pts"
  else
    printf ' %s %-60s (0/%d)\n' "${C_RED}✗${C_RST}" "$desc" "$pts"
  fi
}

grade_finish() {
  local pct=0
  [ "$_G_MAX" -gt 0 ] && pct=$(( _G_EARNED * 100 / _G_MAX ))
  printf '%s\n' " ─────────────────────────────────────────────────────────────"
  if [ "$_G_EARNED" -eq "$_G_MAX" ]; then
    printf ' %s\n\n' "${C_GRN}${C_BLD}Score: $_G_EARNED/$_G_MAX (100%) — 만점${C_RST}"
  else
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

deploy_ready() { # deploy_ready <ns> <name> <ready-replicas>
  [ "$(kctx -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "$3" ]
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
  kctx -n "$1" get endpointslices -l "kubernetes.io/service-name=$2" \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null | grep -q .
}

# 클러스터 내부에서 HTTP 접근 검증 (cka-system의 상주 grader-client 파드 이용)
http_ok() { # http_ok <url>
  kctx -n cka-system exec deploy/grader-client -- wget -q -O /dev/null -T 4 "$1" 2>/dev/null
}

http_body_contains() { # http_body_contains <url> <pattern>
  kctx -n cka-system exec deploy/grader-client -- wget -q -O - -T 4 "$1" 2>/dev/null | grep -q -- "$2"
}

http_denied() { # 접근이 차단되어야 통과 (NetworkPolicy 등)
  ! http_ok "$1"
}

# 특정 파드 안에서 HTTP 접근 검증 (NetworkPolicy 검증용)
http_ok_from() { # http_ok_from <ns> <pod> <url>
  kctx -n "$1" exec "$2" -- wget -q -O /dev/null -T 4 "$3" 2>/dev/null
}

http_denied_from() { ! http_ok_from "$1" "$2" "$3"; }

# 호스트(WSL)에서 ingress-nginx 경유 접근 검증: kind 포트매핑 80→8080
ingress_ok() { # ingress_ok <host-header> <path> [pattern]
  local body
  body="$(curl -s -m 5 -H "Host: $1" "http://localhost:8080$2" 2>/dev/null)" || return 1
  if [ -n "${3:-}" ]; then printf '%s' "$body" | grep -q -- "$3"; else [ -n "$body" ]; fi
}

dns_resolves() { # dns_resolves <fqdn>
  kctx -n cka-system exec deploy/grader-client -- nslookup "$1" 2>/dev/null | grep -q "Address"
}

file_exists() { [ -s "$1" ]; }
file_contains() { grep -Eq -- "$2" "$1" 2>/dev/null; }

# 노드(kind 컨테이너) 안에서 커맨드 실행
node_exec() { docker exec "$1" sh -c "$2" >/dev/null 2>&1; }
node_exec_out() { docker exec "$1" sh -c "$2" 2>/dev/null; }

# 노드에 DaemonSet 관리 외의 Pod가 없으면 성공 (drain 검증)
node_drained() { # node_drained <node>
  ! kctx get pods -A --field-selector "spec.nodeName=$1" \
      -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | grep -qv '^DaemonSet$'
}
