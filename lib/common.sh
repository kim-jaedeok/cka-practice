#!/usr/bin/env bash
# cka-practice 공통 라이브러리 — CLI, 클러스터 스크립트, 문제 스크립트에서 source 한다.

CKA_ROOT="${CKA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CKA_CONTEXT="${CKA_CONTEXT:-kind-cka}"
CKA_CLUSTER_NAME="${CKA_CLUSTER_NAME:-cka}"
CKA_STATE_DIR="${CKA_STATE_DIR:-$CKA_ROOT/.state}"
CKA_WORK_DIR="${CKA_WORK_DIR:-$HOME/cka}"   # 파일 제출형 답안이 저장되는 위치
CKA_LABEL_KEY="cka-practice/question"
CKA_VERSIONS_LOCK="$CKA_ROOT/cluster/versions.lock.yaml"
_CKA_INFRA_ACCOUNT_HOME=""
if command -v getent >/dev/null 2>&1; then
  _CKA_INFRA_ACCOUNT_HOME="$(getent passwd "$(id -u)" 2>/dev/null \
    | awk -F: 'NR == 1 { print $6 }' || true)"
fi
CKA_INFRA_LOCK_CANONICAL_ROOT="${_CKA_INFRA_ACCOUNT_HOME:+${_CKA_INFRA_ACCOUNT_HOME%/}/.local/state/cka-practice}"
CKA_INFRA_LOCK_ROOT="${CKA_INFRA_LOCK_ROOT:-$CKA_INFRA_LOCK_CANONICAL_ROOT}"
CKA_INFRA_LOCK_FILE="${CKA_INFRA_LOCK_ROOT%/}/infrastructure.lock"
CKA_INFRA_LOCK_WAIT_SECONDS="${CKA_INFRA_LOCK_WAIT_SECONDS:-15}"
CKA_INFRA_LOCK_WAIT_MAX_SECONDS=120
CKA_INFRA_LOCK_TIMEOUT_RC=75

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

# Prepare the host-global lock used by the public CLI to serialize operations
# that create, mutate, or remove shared KIND infrastructure and disposable
# cells. A small guardian owns the descriptor, forwards termination signals to
# the mutation process group, and never passes the descriptor to descendants.
_infrastructure_lock_prepare() (
  local root resolved owner mode fs lock_path links
  root="${CKA_INFRA_LOCK_ROOT%/}"
  [ -n "$CKA_INFRA_LOCK_CANONICAL_ROOT" ] || {
    err "현재 UID의 canonical home을 확인하지 못해 infrastructure lock을 만들 수 없습니다."
    return 1
  }
  if [ "$root" != "$CKA_INFRA_LOCK_CANONICAL_ROOT" ]; then
    [ "${CKA_INFRA_LOCK_TEST_OVERRIDE:-0}" = 1 ] || {
      err "infrastructure lock root는 UID별 canonical 경로로 고정됩니다: $CKA_INFRA_LOCK_CANONICAL_ROOT"
      return 1
    }
    case "$root" in
      /tmp/*|/var/tmp/*) ;;
      *) err "test infrastructure lock root는 임시 디렉터리 아래여야 합니다: $root"; return 1 ;;
    esac
  fi
  [[ "$root" = /* ]] && [ -n "$root" ] && [ "$root" != / ] || {
    err "infrastructure lock root는 안전한 절대 경로여야 합니다: $CKA_INFRA_LOCK_ROOT"
    return 1
  }
  umask 077
  mkdir -p -m 0700 -- "$root" || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  resolved="$(realpath -e -- "$root" 2>/dev/null)" || return 1
  [ "$resolved" = "$root" ] || {
    err "infrastructure lock root에는 symlink 경로를 사용할 수 없습니다: $root"
    return 1
  }
  owner="$(stat -c %u -- "$root" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -u)" ] || {
    err "infrastructure lock root 소유자가 현재 사용자와 다릅니다: $root"
    return 1
  }
  chmod 0700 -- "$root" || return 1
  mode="$(stat -c %a -- "$root" 2>/dev/null)" || return 1
  [ "$mode" = 700 ] || return 1
  if [ "${CKA_INFRA_LOCK_ALLOW_NON_NATIVE_STATE:-0}" != 1 ]; then
    fs="$(stat -f -c %T -- "$root" 2>/dev/null)" || return 1
    case "${fs,,}" in
      9p|drvfs|cifs|nfs|nfs4|fuseblk|vfat|exfat|ntfs)
        err "infrastructure lock은 native Linux filesystem에 두어야 합니다: $root ($fs)"
        return 1
        ;;
    esac
  fi

  lock_path="$root/infrastructure.lock"
  if [ -e "$lock_path" ] || [ -L "$lock_path" ]; then
    [ -f "$lock_path" ] && [ ! -L "$lock_path" ] || {
      err "infrastructure lock이 안전한 일반 파일이 아닙니다: $lock_path"
      return 1
    }
    owner="$(stat -c %u -- "$lock_path" 2>/dev/null)" || return 1
    links="$(stat -c %h -- "$lock_path" 2>/dev/null)" || return 1
    mode="$(stat -c %a -- "$lock_path" 2>/dev/null)" || return 1
    [ "$owner" = "$(id -u)" ] && [ "$links" = 1 ] && [ "$mode" = 600 ] || {
      err "infrastructure lock의 소유자·link count·mode가 안전하지 않습니다: $lock_path"
      return 1
    }
  fi
  # The Python guardian creates/opens the leaf with O_NOFOLLOW and validates
  # the acquired descriptor. Do not mutate an existing path before that
  # descriptor-level check.
)

infrastructure_lock_run() { # <wait|nowait> <command> [args...]
  local mode="${1:-}"
  shift || return 2
  [ "$#" -gt 0 ] || return 2
  CKA_INFRA_LOCK_FILE="${CKA_INFRA_LOCK_ROOT%/}/infrastructure.lock"
  _infrastructure_lock_prepare || return 1
  case "$mode" in wait|nowait) ;; *) return 2 ;; esac
  [[ "$CKA_INFRA_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    && [ "$CKA_INFRA_LOCK_WAIT_SECONDS" -le "$CKA_INFRA_LOCK_WAIT_MAX_SECONDS" ] || {
      err "infrastructure lock wait는 1-${CKA_INFRA_LOCK_WAIT_MAX_SECONDS}s여야 합니다."
      return 2
    }
  command -v python3 >/dev/null || { err "python3가 필요합니다."; return 1; }
  python3 "$CKA_ROOT/lib/infrastructure-guard.py" \
    "$mode" "$CKA_INFRA_LOCK_WAIT_SECONDS" "$CKA_INFRA_LOCK_TIMEOUT_RC" \
    "$CKA_INFRA_LOCK_FILE" -- "$@"
}

infrastructure_lock_exec() { # <wait|nowait> <command> [args...]
  local mode="${1:-}"
  shift || return 2
  [ "$#" -gt 0 ] || return 2
  CKA_INFRA_LOCK_FILE="${CKA_INFRA_LOCK_ROOT%/}/infrastructure.lock"
  _infrastructure_lock_prepare || return 1
  case "$mode" in wait|nowait) ;; *) return 2 ;; esac
  [[ "$CKA_INFRA_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    && [ "$CKA_INFRA_LOCK_WAIT_SECONDS" -le "$CKA_INFRA_LOCK_WAIT_MAX_SECONDS" ] || {
      err "infrastructure lock wait는 1-${CKA_INFRA_LOCK_WAIT_MAX_SECONDS}s여야 합니다."
      return 2
    }
  command -v python3 >/dev/null || { err "python3가 필요합니다."; return 1; }
  exec python3 "$CKA_ROOT/lib/infrastructure-guard.py" \
    "$mode" "$CKA_INFRA_LOCK_WAIT_SECONDS" "$CKA_INFRA_LOCK_TIMEOUT_RC" \
    "$CKA_INFRA_LOCK_FILE" -- "$@"
}

# ── 재현 가능한 클러스터 버전 lock ──────────────────────────────
# bootstrap 자체가 yq에 의존하지 않도록 versions.lock.yaml은 의도적으로
# flat key/value 형식만 허용한다. 값은 eval하지 않고 문자열로만 읽는다.
version_lock_get() { # version_lock_get <key>
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" {
      count++
      value = $0
      sub("^" key ":[[:space:]]*", "", value)
      sub("\\r$", "", value)
      if (value !~ /^"[^"]*"$/) {
        invalid = 1
        next
      }
      value = substr(value, 2, length(value) - 2)
    }
    END {
      if (count != 1 || invalid) exit 1
      print value
    }
  ' "$CKA_VERSIONS_LOCK"
}

_version_lock_assign() { # _version_lock_assign <shell-var> <yaml-key>
  local var="$1" key="$2" value
  value="$(version_lock_get "$key")" \
    || die "버전 lock 필수 키가 없습니다: $key ($CKA_VERSIONS_LOCK)"
  [ -n "$value" ] || die "버전 lock 값이 비었습니다: $key"
  printf -v "$var" '%s' "$value"
  export "$var"
}

validate_version_lock() {
  [ -r "$CKA_VERSIONS_LOCK" ] || die "버전 lock 파일을 읽을 수 없습니다: $CKA_VERSIONS_LOCK"
  [ "$CKA_LOCK_SCHEMA_VERSION" = 2 ] || die "지원하지 않는 버전 lock schema: $CKA_LOCK_SCHEMA_VERSION"
  [[ "$KIND_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "kind_version 형식 오류: $KIND_VERSION"
  [ "$KIND_RELEASE_BASE_URL" = "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION" ] \
    || die "KIND release URL/version이 lock 안에서 일치하지 않습니다."
  [[ "$KIND_LINUX_AMD64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$KIND_LINUX_ARM64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "KIND binary sha256 형식 오류"
  [[ "$KUBERNETES_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "kubernetes_version 형식 오류: $KUBERNETES_VERSION"
  [[ "$KIND_NODE_IMAGE" =~ ^kindest/node:${KUBERNETES_VERSION}@sha256:[0-9a-f]{64}$ ]] \
    || die "kind_node_image는 Kubernetes tag + sha256 digest로 고정해야 합니다."
  [[ "$ETCD_IMAGE" =~ ^registry\.k8s\.io/etcd:[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] \
    || die "etcd_image 형식 오류: $ETCD_IMAGE"
  [[ "$CALICO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "calico_version 형식 오류: $CALICO_VERSION"
  [ "$CALICO_MANIFEST_URL" = "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" ] \
    || die "Calico URL/version이 lock 안에서 일치하지 않습니다."
  [[ "$METRICS_SERVER_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "metrics_server_version 형식 오류: $METRICS_SERVER_VERSION"
  [ "$METRICS_SERVER_URL" = "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" ] \
    || die "metrics-server URL/version이 lock 안에서 일치하지 않습니다."
  [[ "$METRICS_SERVER_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "metrics-server manifest sha256 형식 오류"
  [[ "$INGRESS_NGINX_VERSION" =~ ^controller-v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "ingress_nginx_version 형식 오류: $INGRESS_NGINX_VERSION"
  [ "$INGRESS_NGINX_URL" = "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/kind/deploy.yaml" ] \
    || die "ingress-nginx URL/version이 lock 안에서 일치하지 않습니다."
  [[ "$INGRESS_NGINX_CONTROLLER_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] \
    && [ "${INGRESS_NGINX_CONTROLLER_IMAGE%@sha256:*}" = \
      "registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION#controller-}" ] \
    || die "ingress-nginx controller image는 lock 버전 tag + sha256 digest로 고정해야 합니다."
  [[ "$GATEWAY_API_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "gateway_api_version 형식 오류: $GATEWAY_API_VERSION"
  [[ "$HELM_VERSION" =~ ^v3\.[0-9]+\.[0-9]+$ ]] \
    || die "helm_version은 Helm 3의 exact patch여야 합니다: $HELM_VERSION"
  [[ "$HELM_LINUX_AMD64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$HELM_LINUX_ARM64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "Helm archive sha256 형식 오류"
  [[ "$CLOUD_PROVIDER_KIND_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "cloud_provider_kind_version 형식 오류: $CLOUD_PROVIDER_KIND_VERSION"
  [ "$CLOUD_PROVIDER_KIND_RELEASE_BASE_URL" = \
      "https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/$CLOUD_PROVIDER_KIND_VERSION" ] \
    || die "Cloud Provider KIND release URL/version이 lock 안에서 일치하지 않습니다."
  [[ "$CLOUD_PROVIDER_KIND_LINUX_AMD64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$CLOUD_PROVIDER_KIND_LINUX_ARM64_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "Cloud Provider KIND archive sha256 형식 오류"
  [[ "$CLOUD_PROVIDER_KIND_LINUX_AMD64_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$CLOUD_PROVIDER_KIND_LINUX_ARM64_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "Cloud Provider KIND binary sha256 형식 오류"
  [[ "$CLOUD_PROVIDER_KIND_PROXY_IMAGE" =~ ^docker\.io/[a-z0-9._/-]+:v?[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Cloud Provider KIND proxy image 형식 오류: $CLOUD_PROVIDER_KIND_PROXY_IMAGE"
  [[ "$CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST" =~ ^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] \
    || die "Cloud Provider KIND proxy image digest 형식 오류"
  [[ "$CKA_PRELOAD_IMAGES_CSV" =~ ^[A-Za-z0-9._/@:+-]+(,[A-Za-z0-9._/@:+-]+)*$ ]] \
    || die "preload_images_csv 형식 오류: 공백·빈 항목 없이 image ref를 쉼표로 구분해야 합니다."
}

load_version_lock() {
  [ -r "$CKA_VERSIONS_LOCK" ] || die "버전 lock 파일을 읽을 수 없습니다: $CKA_VERSIONS_LOCK"
  _version_lock_assign CKA_LOCK_SCHEMA_VERSION schema_version
  _version_lock_assign KIND_VERSION kind_version
  _version_lock_assign KIND_RELEASE_BASE_URL kind_release_base_url
  _version_lock_assign KIND_LINUX_AMD64_SHA256 kind_linux_amd64_sha256
  _version_lock_assign KIND_LINUX_ARM64_SHA256 kind_linux_arm64_sha256
  _version_lock_assign KUBERNETES_VERSION kubernetes_version
  _version_lock_assign KIND_NODE_IMAGE kind_node_image
  _version_lock_assign ETCD_IMAGE etcd_image
  _version_lock_assign CALICO_VERSION calico_version
  _version_lock_assign CALICO_MANIFEST_URL calico_manifest_url
  _version_lock_assign METRICS_SERVER_VERSION metrics_server_version
  _version_lock_assign METRICS_SERVER_URL metrics_server_manifest_url
  _version_lock_assign METRICS_SERVER_MANIFEST_SHA256 metrics_server_manifest_sha256
  _version_lock_assign INGRESS_NGINX_VERSION ingress_nginx_version
  _version_lock_assign INGRESS_NGINX_URL ingress_nginx_manifest_url
  _version_lock_assign INGRESS_NGINX_CONTROLLER_IMAGE ingress_nginx_controller_image
  _version_lock_assign GATEWAY_API_VERSION gateway_api_version
  _version_lock_assign HELM_VERSION helm_version
  _version_lock_assign HELM_LINUX_AMD64_SHA256 helm_linux_amd64_sha256
  _version_lock_assign HELM_LINUX_ARM64_SHA256 helm_linux_arm64_sha256
  _version_lock_assign CLOUD_PROVIDER_KIND_VERSION cloud_provider_kind_version
  _version_lock_assign CLOUD_PROVIDER_KIND_RELEASE_BASE_URL cloud_provider_kind_release_base_url
  _version_lock_assign CLOUD_PROVIDER_KIND_LINUX_AMD64_SHA256 cloud_provider_kind_linux_amd64_sha256
  _version_lock_assign CLOUD_PROVIDER_KIND_LINUX_ARM64_SHA256 cloud_provider_kind_linux_arm64_sha256
  _version_lock_assign CLOUD_PROVIDER_KIND_LINUX_AMD64_BINARY_SHA256 cloud_provider_kind_linux_amd64_binary_sha256
  _version_lock_assign CLOUD_PROVIDER_KIND_LINUX_ARM64_BINARY_SHA256 cloud_provider_kind_linux_arm64_binary_sha256
  _version_lock_assign CLOUD_PROVIDER_KIND_PROXY_IMAGE cloud_provider_kind_proxy_image
  _version_lock_assign CLOUD_PROVIDER_KIND_PROXY_REPO_DIGEST cloud_provider_kind_proxy_repo_digest
  _version_lock_assign CKA_PRELOAD_IMAGES_CSV preload_images_csv
  validate_version_lock
}

load_version_lock

# 시스템 KIND를 덮어쓰지 않고 lock 버전을 사용자 전용 경로에 검증 설치한다.
kind_locked_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) die "지원하지 않는 KIND 아키텍처: $(uname -m)" ;;
  esac
}

kind_locked_sha256() {
  case "$1" in
    amd64) printf '%s\n' "$KIND_LINUX_AMD64_SHA256" ;;
    arm64) printf '%s\n' "$KIND_LINUX_ARM64_SHA256" ;;
    *) die "지원하지 않는 KIND 아키텍처: $1" ;;
  esac
}

kind_locked_dir() {
  local data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
  printf '%s/cka-practice/tools/kind/%s/linux-%s\n' \
    "$data_root" "$KIND_VERSION" "$(kind_locked_arch)"
}

kind_locked_binary_ok() {
  local binary="$1" expected_sha actual_version
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
  expected_sha="$(kind_locked_sha256 "$(kind_locked_arch)")"
  printf '%s  %s\n' "$expected_sha" "$binary" | sha256sum -c - >/dev/null 2>&1 || return 1
  actual_version="$("$binary" version 2>/dev/null | awk '{print $2; exit}')"
  [ "$actual_version" = "$KIND_VERSION" ]
}

activate_locked_kind() {
  local binary dir
  dir="$(kind_locked_dir)"
  binary="$dir/kind"
  kind_locked_binary_ok "$binary" || return 1
  PATH="$dir:$PATH"
  export PATH
}

ensure_locked_kind() {
  local arch expected_sha dir binary lock_file tmp actual system_kind system_version lock_fd
  activate_locked_kind && return 0

  for actual in curl sha256sum flock mktemp mkdir chmod mv uname awk; do
    command -v "$actual" >/dev/null 2>&1 || die "$actual 이 설치되어 있지 않습니다."
  done

  arch="$(kind_locked_arch)"
  expected_sha="$(kind_locked_sha256 "$arch")"
  dir="$(kind_locked_dir)"
  binary="$dir/kind"
  case "$dir" in
    /*) ;;
    *) die "KIND 전용 경로가 절대 경로가 아닙니다: $dir" ;;
  esac
  [ ! -L "$dir" ] || die "KIND 전용 경로가 심볼릭 링크입니다: $dir"
  mkdir -p -- "$dir" || die "KIND 전용 경로 생성 실패: $dir"
  chmod 0700 -- "$dir" || die "KIND 전용 경로 권한 설정 실패: $dir"

  lock_file="$dir/.install.lock"
  exec {lock_fd}>"$lock_file" || die "KIND 설치 lock 생성 실패"
  flock "$lock_fd" || die "KIND 설치 lock 획득 실패"
  if activate_locked_kind; then
    exec {lock_fd}>&-
    return 0
  fi
  [ ! -L "$binary" ] || die "KIND 캐시 바이너리가 심볼릭 링크입니다: $binary"

  system_kind="$(command -v kind 2>/dev/null || true)"
  system_version="$(kind version 2>/dev/null | awk '{print $2; exit}' || true)"
  info "시스템 KIND(${system_version:-없음})는 유지하고 lock 버전 $KIND_VERSION 을 전용 경로에 설치합니다."

  tmp="$(mktemp "$dir/.kind.download.XXXXXX")" || die "KIND 임시 파일 생성 실패"
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
      "$KIND_RELEASE_BASE_URL/kind-linux-$arch" -o "$tmp"; then
    rm -f -- "$tmp"
    die "KIND $KIND_VERSION 다운로드 실패"
  fi
  if ! printf '%s  %s\n' "$expected_sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f -- "$tmp"
    die "KIND $KIND_VERSION checksum 불일치"
  fi
  chmod 0500 -- "$tmp" || { rm -f -- "$tmp"; die "KIND 실행 권한 설정 실패"; }
  actual="$("$tmp" version 2>/dev/null | awk '{print $2; exit}' || true)"
  if [ "$actual" != "$KIND_VERSION" ]; then
    rm -f -- "$tmp"
    die "다운로드한 KIND 버전 불일치: actual=${actual:-unknown}, lock=$KIND_VERSION"
  fi
  mv -f -- "$tmp" "$binary" || { rm -f -- "$tmp"; die "KIND 전용 바이너리 설치 실패"; }
  activate_locked_kind || die "설치된 KIND 검증 실패: $binary"
  exec {lock_fd}>&-
  ok "KIND $KIND_VERSION 전용 바이너리 준비 완료: $binary"
}

# 이미 설치된 lock 바이너리가 있으면 모든 하위 스크립트에서 우선 사용한다.
activate_locked_kind >/dev/null 2>&1 || true

# 항상 연습 클러스터 컨텍스트로 고정해서 실행 (사용자의 현재 컨텍스트와 무관하게 동작)
kctx() { kubectl --context "$CKA_CONTEXT" "$@"; }

cluster_ready() { kctx --request-timeout=3s get nodes >/dev/null 2>&1; }

# 0=존재, 1=정상 조회됐지만 없음, 2=KIND inventory 조회 자체가 실패함.
# 노드 recovery보다 먼저 호출해, 클러스터가 없는 상태를 identity drift로
# 오진하며 cka-control-plane inspect 오류를 내지 않게 한다.
kind_cluster_exists() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null)" || return 2
  grep -Fxq -- "$CKA_CLUSTER_NAME" <<< "$clusters"
}

# 실행 중인 kind 클러스터가 lock의 Kubernetes/node image와 일치하는지 읽기만 한다.
# 불일치 시 자동 재생성하지 않는다. setup-cluster.sh가 안전하게 중단하고 reset을 안내한다.
cluster_matches_version_lock() {
  local actual node failed=0 expected_nodes actual_nodes
  actual="$(kctx get --raw=/version 2>/dev/null \
    | sed -n 's/.*"gitVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "$actual" != "$KUBERNETES_VERSION" ]; then
    err "Kubernetes server version 불일치: actual=${actual:-unknown}, lock=$KUBERNETES_VERSION"
    failed=1
  fi
  expected_nodes="$(cka_node_names | sort)"
  actual_nodes="$(kind get nodes --name "$CKA_CLUSTER_NAME" 2>/dev/null | sort)"
  if [ "$actual_nodes" != "$expected_nodes" ]; then
    err "kind node 집합 불일치: actual=${actual_nodes//$'\n'/,}, expected=${expected_nodes//$'\n'/,}"
    failed=1
  fi
  for node in $(cka_node_names); do
    actual="$(docker inspect --format '{{.Config.Image}}' "$node" 2>/dev/null || true)"
    if [ "$actual" != "$KIND_NODE_IMAGE" ]; then
      err "$node image 불일치: actual=${actual:-missing}, lock=$KIND_NODE_IMAGE"
      failed=1
    fi
  done
  actual="$(kctx -n kube-system get pod "etcd-${CKA_CLUSTER_NAME}-control-plane" \
    -o jsonpath='{.spec.containers[?(@.name=="etcd")].image}' 2>/dev/null || true)"
  if [ "$actual" != "$ETCD_IMAGE" ]; then
    err "etcd image 불일치: actual=${actual:-missing}, lock=$ETCD_IMAGE"
    failed=1
  fi
  [ "$failed" -eq 0 ]
}

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

# Docker daemon 재기동 뒤 KIND 노드 IP 할당 순서를 보존하기 위한 shared-cluster
# 복구 경계. 이름 조회 결과를 그대로 start하지 않고, 세 노드 전체의 immutable
# ID/소유권/image/network/state를 먼저 검증한 뒤 그 full ID만 사용한다.
CKA_KIND_NETWORK_NAME="kind"
declare -ga CKA_VERIFIED_CLUSTER_IDS=()
declare -ga CKA_VERIFIED_CLUSTER_STATES=()
declare -ga CKA_VERIFIED_CLUSTER_NAMES=()
declare -ga CKA_VERIFIED_CLUSTER_ROLES=()
CKA_VERIFIED_CLUSTER_NETWORK_ID=""
CKA_VERIFIED_CLUSTER_IMAGE_ID=""
CKA_VERIFIED_NODE_ID=""
CKA_VERIFIED_NODE_STATE=""

_cluster_docker_id_valid() { [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; }

_cluster_verify_node_record() { # <name-or-full-id> <expected-name> <expected-role> <network-id> <image-id>
  local target="$1" expected_name="$2" expected_role="$3" network_id="$4" image_id="$5"
  local record id actual_name cluster role image actual_image_id status running paused restarting
  local network_mode network_count network_present attached_network marker extra
  record="$(docker container inspect --format \
    '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.x-k8s.kind.cluster"}}|{{index .Config.Labels "io.x-k8s.kind.role"}}|{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{.State.Running}}|{{.State.Paused}}|{{.State.Restarting}}|{{.HostConfig.NetworkMode}}|{{len .NetworkSettings.Networks}}|{{if index .NetworkSettings.Networks "kind"}}true{{else}}false{{end}}|{{with index .NetworkSettings.Networks "kind"}}{{.NetworkID}}{{end}}|END' \
    "$target" 2>/dev/null)" || {
      err "KIND 노드 container를 정확히 inspect하지 못했습니다: $expected_name"
      return 1
    }
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r id actual_name cluster role image actual_image_id status running paused restarting \
    network_mode network_count network_present attached_network marker extra <<< "$record"
  _cluster_docker_id_valid "$id" \
    && [ "$actual_name" = "/$expected_name" ] \
    && [ "$cluster" = "$CKA_CLUSTER_NAME" ] \
    && [ "$role" = "$expected_role" ] \
    && [ "$image" = "$KIND_NODE_IMAGE" ] \
    && [ "$actual_image_id" = "$image_id" ] \
    && [ "$paused" = false ] \
    && [ "$restarting" = false ] \
    && [ "$network_mode" = "$CKA_KIND_NETWORK_NAME" ] \
    && [ "$network_count" = 1 ] \
    && [ "$network_present" = true ] \
    && [ "$marker" = END ] \
    && [ -z "${extra:-}" ] || {
      err "KIND 노드 identity/state/network 검증 실패: $expected_name"
      return 1
    }
  case "$status|$running" in
    running\|true)
      [ "$attached_network" = "$network_id" ] || return 1
      ;;
    exited\|false)
      [ -z "$attached_network" ] || [ "$attached_network" = "$network_id" ] || return 1
      ;;
    *)
      err "KIND 노드가 안전하게 복구할 수 없는 상태입니다: $expected_name ($status)"
      return 1
      ;;
  esac
  CKA_VERIFIED_NODE_ID="$id"
  CKA_VERIFIED_NODE_STATE="$status"
}

_cluster_verify_exact_inventory() {
  local inventory current_id expected_id count=0 matched
  local -A seen=()
  inventory="$(docker container ls --all --quiet --no-trunc \
    --filter "label=io.x-k8s.kind.cluster=$CKA_CLUSTER_NAME" 2>/dev/null)" || {
      err "KIND cluster container inventory를 읽지 못했습니다."
      return 1
    }
  while IFS= read -r current_id; do
    [ -n "$current_id" ] || continue
    _cluster_docker_id_valid "$current_id" || return 1
    [ -z "${seen[$current_id]:-}" ] || return 1
    matched=0
    for expected_id in "${CKA_VERIFIED_CLUSTER_IDS[@]}"; do
      [ "$current_id" = "$expected_id" ] && matched=1
    done
    [ "$matched" -eq 1 ] || {
      err "예상하지 않은 동일-cluster container를 발견했습니다: $current_id"
      return 1
    }
    seen[$current_id]=1
    count=$((count + 1))
  done <<< "$inventory"
  [ "$count" -eq 3 ] || {
    err "KIND cluster container inventory는 정확히 3개여야 합니다: actual=$count"
    return 1
  }
  for expected_id in "${CKA_VERIFIED_CLUSTER_IDS[@]}"; do
    [ "${seen[$expected_id]:-}" = 1 ] || return 1
  done
}

_cluster_verify_sealed_network() {
  local record actual name marker extra
  record="$(docker network inspect --format '{{.Id}}|{{.Name}}|END' \
    "$CKA_VERIFIED_CLUSTER_NETWORK_ID" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r actual name marker extra <<< "$record"
  [ "$actual" = "$CKA_VERIFIED_CLUSTER_NETWORK_ID" ] \
    && [ "$name" = "$CKA_KIND_NETWORK_NAME" ] \
    && [ "$marker" = END ] \
    && [ -z "${extra:-}" ]
}

_cluster_reverify_sealed_inventory() {
  local i
  _cluster_verify_sealed_network && _cluster_verify_exact_inventory || return 1
  for i in 0 1 2; do
    _cluster_verify_node_record "${CKA_VERIFIED_CLUSTER_IDS[$i]}" \
      "${CKA_VERIFIED_CLUSTER_NAMES[$i]}" "${CKA_VERIFIED_CLUSTER_ROLES[$i]}" \
      "$CKA_VERIFIED_CLUSTER_NETWORK_ID" "$CKA_VERIFIED_CLUSTER_IMAGE_ID" \
      || return 1
    [ "$CKA_VERIFIED_NODE_ID" = "${CKA_VERIFIED_CLUSTER_IDS[$i]}" ] \
      && [ "$CKA_VERIFIED_NODE_STATE" = "${CKA_VERIFIED_CLUSTER_STATES[$i]}" ] \
      || return 1
  done
}

_cluster_capture_verified_inventory() {
  local network_record network_id network_name image_record image_id marker extra i
  local -a names=(
    "${CKA_CLUSTER_NAME}-control-plane"
    "${CKA_CLUSTER_NAME}-worker"
    "${CKA_CLUSTER_NAME}-worker2"
  )
  local -a roles=(control-plane worker worker)

  network_record="$(docker network inspect --format '{{.Id}}|{{.Name}}|END' \
    "$CKA_KIND_NETWORK_NAME" 2>/dev/null)" || {
      err "KIND network를 정확히 inspect하지 못했습니다: $CKA_KIND_NETWORK_NAME"
      return 1
    }
  [ -n "$network_record" ] && [[ "$network_record" != *$'\n'* ]] || return 1
  IFS='|' read -r network_id network_name marker extra <<< "$network_record"
  _cluster_docker_id_valid "$network_id" \
    && [ "$network_name" = "$CKA_KIND_NETWORK_NAME" ] \
    && [ "$marker" = END ] \
    && [ -z "${extra:-}" ] || {
      err "KIND network identity 검증에 실패했습니다: $CKA_KIND_NETWORK_NAME"
      return 1
    }
  image_record="$(docker image inspect --format '{{.Id}}|END' \
    "$KIND_NODE_IMAGE" 2>/dev/null)" || {
      err "lock된 KIND node image를 inspect하지 못했습니다: $KIND_NODE_IMAGE"
      return 1
    }
  [ -n "$image_record" ] && [[ "$image_record" != *$'\n'* ]] || return 1
  IFS='|' read -r image_id marker extra <<< "$image_record"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [ "$marker" = END ] \
    && [ -z "${extra:-}" ] || {
      err "lock된 KIND node image identity 검증에 실패했습니다."
      return 1
    }

  CKA_VERIFIED_CLUSTER_IDS=()
  CKA_VERIFIED_CLUSTER_STATES=()
  CKA_VERIFIED_CLUSTER_NAMES=("${names[@]}")
  CKA_VERIFIED_CLUSTER_ROLES=("${roles[@]}")
  CKA_VERIFIED_CLUSTER_NETWORK_ID="$network_id"
  CKA_VERIFIED_CLUSTER_IMAGE_ID="$image_id"
  for i in 0 1 2; do
    _cluster_verify_node_record "${names[$i]}" "${names[$i]}" "${roles[$i]}" \
      "$network_id" "$image_id" || return 1
    CKA_VERIFIED_CLUSTER_IDS+=("$CKA_VERIFIED_NODE_ID")
    CKA_VERIFIED_CLUSTER_STATES+=("$CKA_VERIFIED_NODE_STATE")
  done
  _cluster_verify_exact_inventory
}

recover_cluster_nodes_ordered() {
  local state_key i id
  local -a order=(1 0 2) # worker -> control-plane -> worker2
  _cluster_capture_verified_inventory || return 1
  state_key="${CKA_VERIFIED_CLUSTER_STATES[0]:0:1}${CKA_VERIFIED_CLUSTER_STATES[1]:0:1}${CKA_VERIFIED_CLUSTER_STATES[2]:0:1}"
  case "$state_key" in
    rrr) return 0 ;;
    eee|ere|rre) ;;
    *)
      err "KIND 노드 실행 상태가 ordered recovery의 안전한 prefix가 아닙니다: $state_key"
      return 1
      ;;
  esac

  for i in "${order[@]}"; do
    [ "${CKA_VERIFIED_CLUSTER_STATES[$i]}" = exited ] || continue
    _cluster_reverify_sealed_inventory || return 1
    id="${CKA_VERIFIED_CLUSTER_IDS[$i]}"
    _cluster_verify_node_record "$id" "${CKA_VERIFIED_CLUSTER_NAMES[$i]}" \
      "${CKA_VERIFIED_CLUSTER_ROLES[$i]}" "$CKA_VERIFIED_CLUSTER_NETWORK_ID" \
      "$CKA_VERIFIED_CLUSTER_IMAGE_ID" \
      || return 1
    [ "$CKA_VERIFIED_NODE_ID" = "$id" ] \
      && [ "$CKA_VERIFIED_NODE_STATE" = exited ] || return 1
    info "중지된 KIND 노드 ordered recovery: ${CKA_VERIFIED_CLUSTER_NAMES[$i]}"
    docker container start "$id" >/dev/null || {
      err "KIND 노드를 시작하지 못했습니다: ${CKA_VERIFIED_CLUSTER_NAMES[$i]}"
      return 1
    }
    _cluster_verify_node_record "$id" "${CKA_VERIFIED_CLUSTER_NAMES[$i]}" \
      "${CKA_VERIFIED_CLUSTER_ROLES[$i]}" "$CKA_VERIFIED_CLUSTER_NETWORK_ID" \
      "$CKA_VERIFIED_CLUSTER_IMAGE_ID" \
      || return 1
    [ "$CKA_VERIFIED_NODE_ID" = "$id" ] \
      && [ "$CKA_VERIFIED_NODE_STATE" = running ] || return 1
    CKA_VERIFIED_CLUSTER_STATES[$i]=running
  done
  _cluster_reverify_sealed_inventory
}

_cluster_restart_policy_get() { # <full-id>
  local id="$1" record actual policy marker extra
  record="$(docker container inspect --format \
    '{{.Id}}|{{.HostConfig.RestartPolicy.Name}}|END' "$id" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r actual policy marker extra <<< "$record"
  [ "$actual" = "$id" ] && [ "$marker" = END ] && [ -z "${extra:-}" ] || return 1
  printf '%s\n' "$policy"
}

configure_cluster_restart_policies() {
  # all-running recovery 자체는 lifecycle을 건드리지 않는다. 기존 정책의 1회
  # migration은 명시적 `cka cluster up`에서 이 helper를 호출할 때만 수행한다.
  local cp_policy worker_policy worker2_policy
  local -a no_ids=()
  _cluster_capture_verified_inventory || return 1
  [ "${CKA_VERIFIED_CLUSTER_STATES[*]}" = "running running running" ] || {
    err "restart policy는 세 KIND 노드가 모두 running일 때만 변경합니다."
    return 1
  }
  cp_policy="$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[0]}")" || return 1
  worker_policy="$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[1]}")" || return 1
  worker2_policy="$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[2]}")" || return 1
  [ "$cp_policy" = no ] || no_ids+=("${CKA_VERIFIED_CLUSTER_IDS[0]}")
  [ "$worker2_policy" = no ] || no_ids+=("${CKA_VERIFIED_CLUSTER_IDS[2]}")

  _cluster_reverify_sealed_inventory || return 1
  if [ "${#no_ids[@]}" -gt 0 ]; then
    docker container update --restart=no "${no_ids[@]}" >/dev/null || {
      err "control-plane/worker2 restart policy를 no로 고정하지 못했습니다."
      return 1
    }
  fi
  if [ "$worker_policy" != unless-stopped ]; then
    _cluster_reverify_sealed_inventory || return 1
    docker container update --restart=unless-stopped \
      "${CKA_VERIFIED_CLUSTER_IDS[1]}" >/dev/null || {
        err "worker restart policy를 unless-stopped로 고정하지 못했습니다."
        return 1
      }
  fi
  [ "$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[0]}")" = no ] \
    && [ "$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[1]}")" = unless-stopped ] \
    && [ "$(_cluster_restart_policy_get "${CKA_VERIFIED_CLUSTER_IDS[2]}")" = no ] || {
      err "KIND 노드 restart policy 사후 검증에 실패했습니다."
      return 1
    }
  _cluster_reverify_sealed_inventory
}

# 노드 하나의 이미지 캐시와 편집기를 준비한다. 호출자는 검증된 immutable
# container ID를 넘기며, 노드 안에서는 layer 경합을 피하려고 이미지를 직렬 처리한다.
_prepare_cluster_node_one() { # <full-id> <display-name> [image ...]
  local id="$1" node="$2" image ref pull_failures=0 editor_installed=0 editor_failures=0
  shift 2
  for image in "$@"; do
    case "$image" in
      */*) ref="$image" ;;
      *) ref="docker.io/library/$image" ;;
    esac
    if [ "${CKA_REFRESH_PRELOAD_IMAGES:-0}" != 1 ] \
        && docker exec "$id" crictl inspecti "$ref" >/dev/null 2>&1; then
      continue
    fi
    if ! docker exec "$id" crictl pull "$ref" >/dev/null 2>&1; then
      warn "$node에 $image 프리로드 실패 (풀이 시 원격 pull로 대체됨)" >&2
      pull_failures=$((pull_failures + 1))
    fi
  done

  if docker exec "$id" sh -c 'command -v vi >/dev/null 2>&1' 2>/dev/null; then
    :
  elif docker exec "$id" sh -c \
      'apt-get update >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y vim nano >/dev/null 2>&1'; then
    editor_installed=1
  else
    warn "$node 편집기 설치 실패 (네트워크 확인). 노드에서 sed/docker cp로 대체 가능." >&2
    editor_failures=1
  fi
  printf '%s|%s|%s\n' "$pull_failures" "$editor_installed" "$editor_failures"
}

# 세 노드 단위로 bounded parallelism을 적용한다. stdout은
# "이미지 실패 수|편집기 신규 설치 노드 수|편집기 실패 노드 수"만 반환한다.
prepare_cluster_nodes() ( # [image ...]
  local tmp_dir="" i line pull installed editor_failed extra worker_failed=0 cleanup_done=0
  local interrupted_signal="" interrupted_status=0
  local total_pull=0 total_installed=0 total_editor_failed=0
  local -a pids=() worker_pending=() result_files=() log_files=()
  cleanup_node_prep_tmp() {
    [ "$cleanup_done" -eq 0 ] || return 0
    cleanup_done=1
    [ -n "$tmp_dir" ] || return 0
    rm -f -- "$tmp_dir/0.result" "$tmp_dir/1.result" "$tmp_dir/2.result" \
      "$tmp_dir/0.log" "$tmp_dir/1.log" "$tmp_dir/2.log" || true
    rmdir -- "$tmp_dir" 2>/dev/null || true
  }
  stop_node_prep_workers() { # <signal> <exit-status>
    local signal_name="$1" exit_status="$2" i pid
    # Prevent a second signal or EXIT from interrupting/re-entering cleanup while
    # children are reaped.  EXIT is cleared because cleanup is called explicitly.
    trap - EXIT
    trap '' HUP INT TERM
    for i in "${!pids[@]}"; do
      [ "${worker_pending[$i]:-0}" -eq 1 ] || continue
      pid="${pids[$i]}"
      kill -s "$signal_name" "$pid" 2>/dev/null || true
    done
    # Non-interactive Bash jobs may inherit SIGINT as ignored.  Preserve the
    # original notification above, then use TERM as the cleanup signal so wait
    # cannot hang forever on an interrupt-ignoring worker.
    if [ "$signal_name" != TERM ]; then
      for i in "${!pids[@]}"; do
        [ "${worker_pending[$i]:-0}" -eq 1 ] || continue
        kill -s TERM "${pids[$i]}" 2>/dev/null || true
      done
    fi
    for i in "${!pids[@]}"; do
      [ "${worker_pending[$i]:-0}" -eq 1 ] || continue
      pid="${pids[$i]}"
      wait "$pid" 2>/dev/null || true
      worker_pending[$i]=0
    done
    cleanup_node_prep_tmp
    exit "$exit_status"
  }
  record_node_prep_signal() { # <signal> <exit-status>
    [ -n "$interrupted_signal" ] && return 0
    interrupted_signal="$1"
    interrupted_status="$2"
  }
  # Install cleanup/termination handlers before the first fallible operation so
  # a signal cannot strand a successfully-created scratch directory.
  trap cleanup_node_prep_tmp EXIT
  trap 'stop_node_prep_workers HUP 129' HUP
  trap 'stop_node_prep_workers INT 130' INT
  trap 'stop_node_prep_workers TERM 143' TERM
  case "${CKA_REFRESH_PRELOAD_IMAGES:-0}" in
    0|1) ;;
    *) warn "CKA_REFRESH_PRELOAD_IMAGES는 0 또는 1이어야 합니다." >&2; return 1 ;;
  esac
  _cluster_capture_verified_inventory || return 1
  # TMPDIR is caller-controlled.  Keep lifecycle scratch data under the fixed
  # system temporary parent; mktemp creates the leaf directory with mode 0700.
  umask 077
  tmp_dir="$(mktemp -d /tmp/cka-node-prep.XXXXXX)" || return 1
  # During `worker & pid=$!`, defer termination until the just-started PID has
  # been recorded.  This closes the signal window between launch and assignment.
  trap 'record_node_prep_signal HUP 129' HUP
  trap 'record_node_prep_signal INT 130' INT
  trap 'record_node_prep_signal TERM 143' TERM

  for i in 0 1 2; do
    if [ -n "$interrupted_signal" ]; then
      stop_node_prep_workers "$interrupted_signal" "$interrupted_status"
    fi
    result_files[$i]="$tmp_dir/$i.result"
    log_files[$i]="$tmp_dir/$i.log"
    _prepare_cluster_node_one "${CKA_VERIFIED_CLUSTER_IDS[$i]}" \
      "${CKA_VERIFIED_CLUSTER_NAMES[$i]}" "$@" \
      >"${result_files[$i]}" 2>"${log_files[$i]}" &
    pids[$i]=$!
    worker_pending[$i]=1
    if [ -n "$interrupted_signal" ]; then
      stop_node_prep_workers "$interrupted_signal" "$interrupted_status"
    fi
  done
  trap 'stop_node_prep_workers HUP 129' HUP
  trap 'stop_node_prep_workers INT 130' INT
  trap 'stop_node_prep_workers TERM 143' TERM
  if [ -n "$interrupted_signal" ]; then
    stop_node_prep_workers "$interrupted_signal" "$interrupted_status"
  fi

  # Bash의 wait는 마지막으로 기다린 PID의 상태만 대신 반환하지 않도록 각 PID를
  # 따로 수집한다. 한 worker가 실패해도 나머지 두 worker는 반드시 reap한다.
  for i in 0 1 2; do
    wait "${pids[$i]}" || worker_failed=1
    worker_pending[$i]=0
    if [ -s "${log_files[$i]}" ]; then
      while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "${log_files[$i]}"
    fi
    if ! IFS='|' read -r pull installed editor_failed extra < "${result_files[$i]}"; then
      worker_failed=1
      continue
    fi
    [[ "$pull" =~ ^[0-9]+$ ]] && [[ "$installed" =~ ^[0-9]+$ ]] \
      && [[ "$editor_failed" =~ ^[0-9]+$ ]] && [ -z "${extra:-}" ] || {
        worker_failed=1
        continue
      }
    total_pull=$((total_pull + pull))
    total_installed=$((total_installed + installed))
    total_editor_failed=$((total_editor_failed + editor_failed))
  done
  # A worker only performs non-fatal cache/editor preparation.  After all workers
  # are reaped, require the exact sealed node generation to still be present.
  _cluster_reverify_sealed_inventory || worker_failed=1
  printf '%s|%s|%s' "$total_pull" "$total_installed" "$total_editor_failed"
  [ "$worker_failed" -eq 0 ]
)

# 모든 노드에 vi가 있으면 0(정상). 이름 대신 검증된 immutable ID만 사용한다.
node_editors_ok() {
  local id
  _cluster_capture_verified_inventory >/dev/null 2>&1 || return 1
  for id in "${CKA_VERIFIED_CLUSTER_IDS[@]}"; do
    docker exec "$id" sh -c 'command -v vi >/dev/null 2>&1' 2>/dev/null || return 1
  done
}

# 편집기가 없는 노드에만 병렬 설치. 실제로 설치한 노드 수를 echo(멱등).
install_node_editors() {
  local summary pull_failures repaired failed extra
  if ! summary="$(prepare_cluster_nodes)"; then
    warn "검증된 KIND 노드에서 편집기 설치 작업을 시작하지 못했습니다." >&2
    printf '0'
    return 0
  fi
  IFS='|' read -r pull_failures repaired failed extra <<< "$summary"
  printf '%s' "${repaired:-0}"
}

# ── 노드 etcdctl/etcdutl (실전과 동일한 etcd 작업 환경) ──────────
# 실제 CKA 시험은 control plane 노드에 ssh로 들어가 노드의 etcdctl을 쓴다.
# kind 노드 이미지에는 etcdctl이 없어서 예전에는 `kubectl exec etcd-... -- etcdctl`
# 로 우회했는데, 실전에 없는 명령이 손에 익는 손해가 있다. etcd 이미지는 이미
# 노드에 받아져 있으므로 실행 중인 etcd 컨테이너의 proc rootfs에서 바이너리를
# 꺼내 노드에 설치한다 (네트워크·containerd snapshot mount 불필요).
CKA_CP_NODE_SUFFIX="control-plane"

cka_cp_node() { printf '%s' "${CKA_CLUSTER_NAME}-${CKA_CP_NODE_SUFFIX}"; }

_node_etcdctl_ok_by_id() { # <verified-control-plane-full-id>
  local node_id="$1"
  _cluster_docker_id_valid "$node_id" || return 1
  docker exec "$node_id" sh -c \
    'command -v etcd >/dev/null 2>&1 && command -v etcdctl >/dev/null 2>&1 && command -v etcdutl >/dev/null 2>&1' 2>/dev/null
}

node_etcdctl_ok() {
  local node_id
  _cluster_capture_verified_inventory >/dev/null 2>&1 || return 1
  [ "${CKA_VERIFIED_CLUSTER_STATES[0]:-}" = running ] || return 1
  node_id="${CKA_VERIFIED_CLUSTER_IDS[0]:-}"
  _node_etcdctl_ok_by_id "$node_id"
}

# control plane 노드에 etcdctl·etcdutl 설치 (멱등). 설치했으면 0, 이미 있으면 1.
install_node_etcdctl() {
  local node node_id container_id container_pid
  _cluster_capture_verified_inventory || {
    warn "control plane 노드 identity를 검증하지 못해 etcd 도구를 설치하지 않습니다." >&2
    return 1
  }
  [ "${CKA_VERIFIED_CLUSTER_STATES[0]:-}" = running ] || {
    warn "control plane 노드가 running 상태가 아니어서 etcd 도구를 설치하지 않습니다." >&2
    return 1
  }
  node="${CKA_VERIFIED_CLUSTER_NAMES[0]}"
  node_id="${CKA_VERIFIED_CLUSTER_IDS[0]}"
  _cluster_docker_id_valid "$node_id" || {
    warn "control plane 노드의 full container ID가 유효하지 않아 etcd 도구를 설치하지 않습니다." >&2
    return 1
  }
  _node_etcdctl_ok_by_id "$node_id" && return 1

  container_id="$(docker exec "$node_id" crictl ps -q \
    --label io.kubernetes.container.name=etcd 2>/dev/null)"
  [[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || {
    warn "$node 의 실행 중인 etcd 컨테이너를 하나로 식별하지 못했습니다." >&2
    return 1
  }
  container_pid="$(docker exec "$node_id" crictl inspect -o go-template \
    --template '{{.info.pid}}' "$container_id" 2>/dev/null)"
  [[ "$container_pid" =~ ^[1-9][0-9]*$ ]] || {
    warn "$node 의 etcd 컨테이너 PID를 확인하지 못했습니다." >&2
    return 1
  }

  # Discovery above is read-only.  Reverify the sealed inventory immediately
  # before the first mutation; the mutation itself targets only the captured ID.
  _cluster_reverify_sealed_inventory || {
    warn "$node identity가 설치 준비 중 변경되어 etcd 도구를 설치하지 않습니다." >&2
    return 1
  }
  [ "${CKA_VERIFIED_CLUSTER_IDS[0]}" = "$node_id" ] \
    && [ "${CKA_VERIFIED_CLUSTER_STATES[0]}" = running ] || return 1

  docker exec "$node_id" sh -c "
    set -e
    test -x '/proc/$container_pid/root/usr/local/bin/etcd'
    test -x '/proc/$container_pid/root/usr/local/bin/etcdctl'
    test -x '/proc/$container_pid/root/usr/local/bin/etcdutl'
    install -m 0755 '/proc/$container_pid/root/usr/local/bin/etcd' /usr/local/bin/etcd
    install -m 0755 '/proc/$container_pid/root/usr/local/bin/etcdctl' /usr/local/bin/etcdctl
    install -m 0755 '/proc/$container_pid/root/usr/local/bin/etcdutl' /usr/local/bin/etcdutl
  " >/dev/null 2>&1 || {
    warn "$node 에 etcdctl·etcdutl 설치 실패" >&2
    return 1
  }
  _cluster_reverify_sealed_inventory || return 1
  [ "${CKA_VERIFIED_CLUSTER_IDS[0]}" = "$node_id" ] \
    && [ "${CKA_VERIFIED_CLUSTER_STATES[0]}" = running ] || return 1
  _node_etcdctl_ok_by_id "$node_id" || return 1
  return 0
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

# 채점 전 검사는 관찰만 해야 한다. 특히 CoreDNS/Ingress 장애 문제를 채점하기 직전에
# 애드온을 복구하면 오답 상태가 사라져 버린다.
require_cluster_readonly() {
  _wait_api
}

# 일반 연습 시작/reset/doctor 경로용 명시적 복구. 기존 require_cluster의 동작을
# 유지하되 mutation의 이름과 경계를 분명히 한다.
repair_cluster() {
  local exists_rc=0
  kind_cluster_exists || exists_rc=$?
  case "$exists_rc" in
    0) ;;
    1)
      err "KIND 클러스터 '$CKA_CLUSTER_NAME'가 없습니다. 먼저 './cka cluster up'을 실행하세요."
      return 1
      ;;
    *)
      err "KIND 클러스터 inventory를 읽지 못했습니다. Docker daemon과 KIND 설치를 확인하세요."
      return 1
      ;;
  esac
  if ! recover_cluster_nodes_ordered; then
    err "KIND 노드 identity 검증 또는 ordered recovery에 실패했습니다."
    return 1
  fi
  require_cluster_readonly
  local repaired
  if ! repaired="$(ensure_addons)"; then
    err "클러스터 애드온 복구 또는 readiness/version 검증에 실패했습니다."
    return 1
  fi
  [ "${repaired:-0}" -gt 0 ] && ok "클러스터 애드온 $repaired건 자동 복구 완료."
  return 0
}

# 하위 호환 entrypoint: 기존 호출자와 똑같이 API 확인 후 애드온을 복구한다.
# grader는 require_cluster_readonly를 명시적으로 호출해야 하며, 호출 스택이나
# 환경 변수에 따라 이 함수의 의미가 바뀌지 않게 유지한다.
require_cluster() {
  repair_cluster
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

# 새 모의고사 runner와 CLI/web guard가 공유하는 최소 상태 인터페이스.
# 파일이 없을 때만 NONE이다. 손상되거나 읽을 수 없는 상태는 fail-closed로 잠근다.
exam_state_get() {
  local state="" path="$CKA_STATE_DIR/exam/state"
  [ -e "$path" ] || { printf '%s\n' NONE; return 0; }
  [ -r "$path" ] || { printf '%s\n' CORRUPT; return 0; }
  IFS= read -r state < "$path" || true
  state="${state%$'\r'}"
  case "$state" in
    PREPARING|RUNNING|SEALED|GRADING|ARCHIVED|INVALID) printf '%s\n' "$state" ;;
    *) printf '%s\n' CORRUPT ;;
  esac
}

exam_actions_locked() {
  case "$(exam_state_get)" in
    NONE|ARCHIVED|INVALID) return 1 ;;
    *) return 0 ;;
  esac
}

# The supervised SSH runner has a separate native-Linux state root. Presence
# of its create-once active record blocks practice mutations. An existing but
# unsafe root also locks fail-closed; the runner performs full run-integrity
# validation when `cka exam-ssh cleanup` is invoked.
supervised_exam_actions_locked() {
  local state_home root active resolved owner mode
  state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  root="${CKA_SSH_RUNNER_STATE_ROOT:-$state_home/cka-practice/exam-ssh}"
  root="${root%/}"
  [[ "$root" = /* ]] && [ -n "$root" ] && [ "$root" != / ] || return 0
  active="$root/active"
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    return 1
  fi
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  resolved="$(realpath -e -- "$root" 2>/dev/null)" || return 0
  [ "$resolved" = "$root" ] || return 0
  owner="$(stat -c %u -- "$root" 2>/dev/null)" || return 0
  mode="$(stat -c %a -- "$root" 2>/dev/null)" || return 0
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 700 ] || return 0
  [ -e "$active" ] || [ -L "$active" ]
}

# Remove one direct child of the CKA state directory.  Destructive callers
# must not trust a user-provided CKA_STATE_DIR until its canonical path and the
# exact child target have both been checked.
state_subdir_clear() { # <single-child-name>
  local child="${1:-}" requested root target
  [[ "$child" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [ -n "${CKA_STATE_DIR:-}" ] && [[ "$CKA_STATE_DIR" = /* ]] || return 1
  requested="${CKA_STATE_DIR%/}"
  [ -n "$requested" ] && [ "$requested" != / ] || return 1
  [ ! -L "$requested" ] || return 1
  mkdir -p -- "$requested" || return 1
  [ -d "$requested" ] && [ ! -L "$requested" ] || return 1
  root="$(realpath -e -- "$requested")" || return 1
  [ "$root" = "$requested" ] && [ "$root" != / ] || return 1
  target="$root/$child"
  [ "$target" = "$root/$child" ] || return 1
  if [ -L "$target" ]; then
    err "symlink인 상태 경로는 자동 삭제하지 않습니다: $target"
    return 1
  fi
  [ ! -e "$target" ] || [ -d "$target" ] || return 1
  rm -rf -- "$target"
}

question_state_clear() { # <qid>
  local id="${1:-}" requested root question_root target
  [[ "$id" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]] || return 1
  [ -n "${CKA_STATE_DIR:-}" ] && [[ "$CKA_STATE_DIR" = /* ]] || return 1
  requested="${CKA_STATE_DIR%/}"
  [ -n "$requested" ] && [ "$requested" != / ] && [ ! -L "$requested" ] || return 1
  mkdir -p -- "$requested" || return 1
  root="$(realpath -e -- "$requested")" || return 1
  [ "$root" = "$requested" ] && [ "$root" != / ] || return 1
  question_root="$root/question-data"
  [ ! -L "$question_root" ] || return 1
  mkdir -p -- "$question_root" || return 1
  [ "$(realpath -e -- "$question_root")" = "$question_root" ] || return 1
  target="$question_root/$id"
  [ ! -L "$target" ] || return 1
  [ ! -e "$target" ] || [ -d "$target" ] || return 1
  rm -rf -- "$target"
}

# ── setup.sh 헬퍼 ────────────────────────────────────────────────
# 문제가 만든 리소스는 전부 라벨(cka-practice/question=<id>)로 추적한다.

# 해당 문제의 리소스 일괄 삭제 (idempotent한 setup을 위해 항상 먼저 호출)
cleanup_question() {
  local id="$1" failed=0
  [[ "$id" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]] || return 1
  kctx delete ns -l "$CKA_LABEL_KEY=$id" --ignore-not-found --wait=true \
    --timeout=90s >/dev/null 2>&1 || failed=1
  kctx delete pv,storageclass,priorityclass,clusterrole,clusterrolebinding \
    -l "$CKA_LABEL_KEY=$id" --ignore-not-found --wait=true --timeout=90s \
    >/dev/null 2>&1 || failed=1
  # Extension APIs are intentionally absent from some disposable cells.  An
  # absent Gateway API CRD means there is nothing to clean, not that cleanup
  # failed.  Once the CRD exists, however, deletion failures remain fatal.
  if kctx get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    kctx delete gatewayclass -l "$CKA_LABEL_KEY=$id" --ignore-not-found \
      --wait=true --timeout=90s >/dev/null 2>&1 || failed=1
  fi
  workdir_clear "$id" || failed=1
  return "$failed"
}

# 문제용 네임스페이스 생성 + 라벨링: recreate_ns <qid> <ns...>
recreate_ns() {
  local id="$1"; shift
  local ns
  for ns in "$@"; do
    kctx delete namespace "$ns" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1
    kctx create namespace "$ns" >/dev/null
    kctx label namespace "$ns" "$CKA_LABEL_KEY=$id" --overwrite >/dev/null
  done
}

# 파일 제출형 문제의 작업 디렉토리 안전 정리/준비.
workdir_root_resolve() {
  local requested root
  [ -n "${CKA_WORK_DIR:-}" ] && [[ "$CKA_WORK_DIR" = /* ]] || return 1
  requested="${CKA_WORK_DIR%/}"
  [ -n "$requested" ] && [ "$requested" != / ] || return 1
  [ ! -L "$requested" ] || return 1
  mkdir -p -- "$requested" || return 1
  root="$(realpath -e -- "$requested")" || return 1
  [ "$root" = "$requested" ] && [ "$root" != / ] || return 1
  printf '%s\n' "$root"
}

workdir_clear() { # <qid>
  local id="$1" root target
  [[ "$id" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]] || return 1
  root="$(workdir_root_resolve)" || return 1
  target="$root/$id"
  if [ -L "$target" ]; then
    err "symlink인 문제 작업 경로는 자동 삭제하지 않습니다: $target"
    return 1
  fi
  [ ! -e "$target" ] || [ -d "$target" ] || return 1
  rm -rf -- "$target"
}

workdir_reset() { # <qid>
  local id="$1" root
  workdir_clear "$id" || return 1
  root="$(workdir_root_resolve)" || return 1
  mkdir -p -- "$root/$id"
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
