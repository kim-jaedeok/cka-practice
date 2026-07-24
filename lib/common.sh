#!/usr/bin/env bash
# cka-practice 공통 라이브러리 — CLI, 클러스터 스크립트, 문제 스크립트에서 source 한다.

CKA_ROOT="${CKA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CKA_CONTEXT="${CKA_CONTEXT:-kind-cka}"
CKA_CLUSTER_NAME="${CKA_CLUSTER_NAME:-cka}"
CKA_STATE_DIR="$CKA_ROOT/.state"
CKA_WORK_DIR="${CKA_WORK_DIR:-$HOME/cka}"   # 파일 제출형 답안이 저장되는 위치
CKA_LABEL_KEY="cka-practice/question"

# helm 등 사용자 로컬 바이너리 경로 보장 (비로그인 셸 대비)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info() { printf '%s\n' "${C_BLU}[info]${C_RST} $*"; }
ok()   { printf '%s\n' "${C_GRN}[ ok ]${C_RST} $*"; }
warn() { printf '%s\n' "${C_YLW}[warn]${C_RST} $*"; }
err()  { printf '%s\n' "${C_RED}[fail]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

# 항상 연습 클러스터 컨텍스트로 고정해서 실행 (사용자의 현재 컨텍스트와 무관하게 동작)
kctx() { kubectl --context "$CKA_CONTEXT" "$@"; }

cluster_ready() { kctx get nodes >/dev/null 2>&1; }

# ── 노드 편집기 (연습 환경 편의) ──────────────────────────────────
# kind 노드 이미지는 최소 구성이라 vi/vim/nano가 없다. 실전 CKA 시험 노드에는
# 편집기가 기본 설치돼 있으므로(ts-12처럼 매니페스트를 직접 고치는 문제 대비),
# 연습 환경도 동일하게 맞춰 준다. apt 설치라 네트워크가 필요하며, 실패해도
# 문제 풀이는 sed/docker cp로 대체 가능하므로 비치명적으로 처리한다.
cka_node_names() {
  printf '%s\n' "${CKA_CLUSTER_NAME}-control-plane" \
                "${CKA_CLUSTER_NAME}-worker" \
                "${CKA_CLUSTER_NAME}-worker2"
}

# 모든 노드에 vi가 있으면 0(정상)
node_editors_ok() {
  local node
  for node in $(cka_node_names); do
    docker exec "$node" sh -c 'command -v vi >/dev/null 2>&1' || return 1
  done
}

# 편집기가 없는 노드에만 vim·nano 설치. 실제로 설치한 노드 수를 echo(멱등).
install_node_editors() {
  local node repaired=0
  for node in $(cka_node_names); do
    docker exec "$node" sh -c 'command -v vi >/dev/null 2>&1' 2>/dev/null && continue
    if docker exec "$node" sh -c \
        'apt-get update >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y vim nano >/dev/null 2>&1'; then
      repaired=$((repaired + 1))
    else
      warn "$node 편집기 설치 실패 (네트워크 확인). 노드에서 sed/docker cp로 대체 가능." >&2
    fi
  done
  printf '%s' "$repaired"
}

# 애드온 설치·점검 함수 (metrics-server·ingress-nginx·gateway-api·grader-client)
source "$(dirname "${BASH_SOURCE[0]}")/addons.sh"

# API가 준비될 때까지만 기다린다 (애드온 점검은 하지 않음)
_wait_api() {
  cluster_ready && return 0
  kind get clusters 2>/dev/null | grep -qx "$CKA_CLUSTER_NAME" \
    || die "클러스터가 없습니다. 먼저 'cka cluster up' 을 실행하세요."
  info "클러스터 기동 대기 중... (WSL 재시작 직후에는 1~2분 걸릴 수 있습니다)"
  local i
  for i in $(seq 1 60); do
    cluster_ready && return 0
    sleep 2
  done
  die "클러스터에 연결할 수 없습니다. 'cka cluster status' 로 상태를 확인하세요."
}

# WSL 재시작·중단된 셋업으로 애드온이 유실되면 문제 풀이가 조용히 깨진다.
# 그래서 문제 시작·채점 전에 API 기동을 기다린 뒤 빠진 애드온을 자동 복구한다.
# (install은 apply 기반이라 멱등 — 정상일 땐 빠른 존재 점검만 하고 넘어간다.)
require_cluster() {
  _wait_api
  local repaired; repaired="$(ensure_addons)"
  [ "${repaired:-0}" -gt 0 ] && ok "클러스터 애드온 $repaired건 자동 복구 완료."
  return 0
}

# 문제 ID → 도메인 디렉토리
domain_of() {
  case "$1" in
    st-*) echo storage ;;
    wl-*) echo workloads-scheduling ;;
    sn-*) echo services-networking ;;
    ca-*) echo cluster-architecture ;;
    ts-*) echo troubleshooting ;;
    *) return 1 ;;
  esac
}

qdir_of() {
  local d p
  d="$(domain_of "$1")" || return 1
  p="$CKA_ROOT/questions/$d/$1"
  [ -d "$p" ] || return 1
  printf '%s\n' "$p"
}

# meta.yaml에서 단순 key: value 읽기
meta_get() { sed -n "s/^$2:[[:space:]]*//p" "$1/meta.yaml" | head -1; }

state_set() { mkdir -p "$CKA_STATE_DIR/status"; printf '%s' "$2" > "$CKA_STATE_DIR/status/$1"; }
state_get() { cat "$CKA_STATE_DIR/status/$1" 2>/dev/null || printf '%s' "-"; }
state_clear() { rm -f "$CKA_STATE_DIR/status/$1"; }

# ── setup.sh 헬퍼 ────────────────────────────────────────────────
# 문제가 만든 리소스는 전부 라벨(cka-practice/question=<id>)로 추적한다.

# 해당 문제의 리소스 일괄 삭제 (idempotent한 setup을 위해 항상 먼저 호출)
cleanup_question() {
  local id="$1"
  kctx delete ns -l "$CKA_LABEL_KEY=$id" --ignore-not-found --wait=true >/dev/null 2>&1
  kctx delete pv,storageclass,priorityclass,clusterrole,clusterrolebinding \
    -l "$CKA_LABEL_KEY=$id" --ignore-not-found >/dev/null 2>&1
  kctx delete gatewayclass -l "$CKA_LABEL_KEY=$id" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "${CKA_WORK_DIR:?}/$id"
}

# 문제용 네임스페이스 생성 + 라벨링: recreate_ns <qid> <ns...>
recreate_ns() {
  local id="$1"; shift
  local ns
  for ns in "$@"; do
    kctx delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
    kctx create namespace "$ns" >/dev/null
    kctx label namespace "$ns" "$CKA_LABEL_KEY=$id" --overwrite >/dev/null
  done
}

# 파일 제출형 문제의 작업 디렉토리 준비: workdir_reset <qid>
workdir_reset() {
  rm -rf "${CKA_WORK_DIR:?}/$1"
  mkdir -p "$CKA_WORK_DIR/$1"
}

wait_deploy() { # wait_deploy <ns> <name> [timeout]
  kctx -n "$1" rollout status "deploy/$2" --timeout="${3:-120s}" >/dev/null 2>&1
}

wait_pod() { # wait_pod <ns> <pod-name> [timeout]
  kctx -n "$1" wait --for=condition=Ready "pod/$2" --timeout="${3:-120s}" >/dev/null 2>&1
}

wait_pods_selector() { # wait_pods_selector <ns> <selector> [timeout]
  kctx -n "$1" wait --for=condition=Ready pods -l "$2" --timeout="${3:-120s}" >/dev/null 2>&1
}
