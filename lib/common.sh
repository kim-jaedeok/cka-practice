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

# bin/ 의 래퍼(ssh 등)를 항상 우선한다 — setup/solve/grade 스크립트에서도 동일하게 동작
case ":$PATH:" in
  *":$CKA_ROOT/bin:"*) : ;;
  *) PATH="$CKA_ROOT/bin:$PATH" ;;
esac
export PATH

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

# ── ssh 래퍼 (실전과 동일한 노드 접속 명령) ──────────────────────
# 실전 시험은 `ssh <node>`로 노드에 들어가지만 kind 노드에는 sshd가 없다.
# bin/ssh 래퍼가 docker exec으로 바꿔 실행하므로, PATH에만 올라가 있으면
# 지문·정답지·실제 풀이 모두 실전과 같은 `ssh <node>`를 쓸 수 있다.
CKA_RC_BEGIN='# >>> cka-practice >>>'
CKA_RC_END='# <<< cka-practice <<<'

ssh_wrapper_ok() { [ -x "$CKA_ROOT/bin/ssh" ]; }

# ~/.bashrc 에 bin/ 경로를 멱등하게 등록한다 (변경했으면 0, 이미 최신이면 1).
# 웹 터미널은 serve.sh가 PATH를 직접 넣지만, 사용자가 직접 연 WSL 셸에서도
# `ssh cka-worker`가 되도록 로그인 셸 설정에 한 줄을 심어 둔다.
ensure_shell_path() {
  local rc="$HOME/.bashrc"
  local line="export PATH=\"$CKA_ROOT/bin:\$PATH\"   # cka: ssh <node> 래퍼"
  [ -e "$rc" ] || : > "$rc"
  if grep -Fq "$CKA_RC_BEGIN" "$rc" 2>/dev/null; then
    grep -Fqx "$line" "$rc" && return 1                 # 이미 동일 내용
    sed -i "\|^$CKA_RC_BEGIN\$|,\|^$CKA_RC_END\$|d" "$rc"   # 옛 블록 제거 후 재작성
  fi
  printf '\n%s\n%s\n%s\n' "$CKA_RC_BEGIN" "$line" "$CKA_RC_END" >> "$rc"
  return 0
}

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

cka_control_plane_node() { printf '%s' "${CKA_CLUSTER_NAME}-control-plane"; }

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

# ── 노드 etcdctl·etcdutl (control-plane) ──────────────────────────
# 실전 시험 노드에는 etcdctl이 설치돼 있어 `ssh <cp>` 후 바로 스냅샷을 뜬다.
# kind 노드에는 없고 etcd Pod(distroless) 안에만 있어 ca-03/ca-04가 kubectl exec
# 우회를 강요받았다. 실행 중인 etcd 이미지와 같은 버전의 릴리스를 받아 노드
# /usr/local/bin에 심어 실전과 같은 손버릇으로 풀 수 있게 한다. 편집기 설치와
# 마찬가지로 실패해도 Pod exec으로 대체 가능하므로 비치명적으로 처리한다.
node_etcdctl_ok() {
  docker exec "$(cka_control_plane_node)" sh -c \
    'command -v etcdctl >/dev/null 2>&1 && command -v etcdutl >/dev/null 2>&1'
}

# 없을 때만 설치하고 설치했으면 1, 아니면 0을 echo(멱등).
install_node_etcdctl() {
  local cp img ver arch tmp
  cp="$(cka_control_plane_node)"
  node_etcdctl_ok 2>/dev/null && { printf '0'; return; }
  # 실행 중인 etcd static pod 이미지에서 버전 추출: registry.k8s.io/etcd:3.5.15-0 → 3.5.15
  img="$(kctx -n kube-system get pod "etcd-$cp" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
  ver="${img##*:}"; ver="${ver%%-*}"
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) warn "etcd 이미지 버전 확인 실패 (${img:-없음}) — etcdctl 노드 설치를 건너뜁니다." >&2
       printf '0'; return ;;
  esac
  case "$(docker exec "$cp" uname -m 2>/dev/null)" in
    aarch64|arm64) arch=arm64 ;;
    *) arch=amd64 ;;
  esac
  # 호스트에서 받아 docker cp — 노드의 curl/tar/네트워크 유무에 의존하지 않는다
  tmp="$(mktemp -d)"
  if curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ver}/etcd-v${ver}-linux-${arch}.tar.gz" \
        | tar -xz -C "$tmp" 2>/dev/null \
     && docker cp "$tmp/etcd-v${ver}-linux-${arch}/etcdctl" "$cp:/usr/local/bin/etcdctl" >/dev/null 2>&1 \
     && docker cp "$tmp/etcd-v${ver}-linux-${arch}/etcdutl" "$cp:/usr/local/bin/etcdutl" >/dev/null 2>&1 \
     && docker exec "$cp" chmod +x /usr/local/bin/etcdctl /usr/local/bin/etcdutl 2>/dev/null; then
    rm -rf "$tmp"; printf '1'
  else
    rm -rf "$tmp"
    warn "$cp etcdctl·etcdutl 설치 실패 (네트워크 확인). etcd Pod exec로 대체 가능." >&2
    printf '0'
  fi
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
