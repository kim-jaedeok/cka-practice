#!/usr/bin/env bash
# CKA 연습 클러스터 셋업: kind 3노드 + Calico + metrics-server + ingress-nginx
# + Gateway API CRD + helm + Cloud Provider KIND + 이미지 프리로드 + ssh 래퍼
# + 채점용 상주 파드
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

IFS=',' read -r -a PRELOAD_IMAGES <<< "$CKA_PRELOAD_IMAGES_CSV"

step() { printf '\n%s\n' "${C_BLD}── $* ──${C_RST}"; }

for bin in docker kubectl curl sha256sum tar install flock nohup; do
  command -v "$bin" >/dev/null || die "$bin 이 설치되어 있지 않습니다."
done
docker info >/dev/null 2>&1 || die "docker 데몬에 연결할 수 없습니다."

ensure_locked_kind
actual_kind_version="$(kind version 2>/dev/null | awk '{print $2; exit}')"
[ "$actual_kind_version" = "$KIND_VERSION" ] \
  || die "kind 버전 불일치: actual=${actual_kind_version:-unknown}, lock=$KIND_VERSION"

# checksum 검증이 필요한 다운로드와 Helm 압축 해제에만 쓰는 임시 디렉토리.
SETUP_TMP_DIR="$(mktemp -d /tmp/cka-setup.XXXXXX)" || die "임시 디렉토리 생성 실패"
cleanup_setup_tmp() {
  case "$SETUP_TMP_DIR" in
    /tmp/cka-setup.*) rm -rf -- "$SETUP_TMP_DIR" ;;
    *) warn "예상 밖 임시 경로라 삭제하지 않습니다: $SETUP_TMP_DIR" ;;
  esac
}
trap cleanup_setup_tmp EXIT

download_locked() { # download_locked <url> <sha256> <destination>
  local url="$1" sha="$2" dest="$3"
  curl -fsSL "$url" -o "$dest" || die "다운로드 실패: $url"
  printf '%s  %s\n' "$sha" "$dest" | sha256sum -c - >/dev/null \
    || die "checksum 불일치: $url"
}

step "1/9 kind 클러스터 생성 (name: $CKA_CLUSTER_NAME)"
if kind get clusters 2>/dev/null | grep -qx "$CKA_CLUSTER_NAME"; then
  info "클러스터가 이미 존재합니다. lock 일치 여부를 검사합니다."
  recover_cluster_nodes_ordered \
    || die "기존 클러스터의 identity 검증 또는 ordered recovery에 실패했습니다."
  _wait_api
  cluster_matches_version_lock \
    || die "기존 클러스터가 versions.lock.yaml과 다릅니다. './cka cluster reset'으로 명시적으로 재생성하세요."
else
  # A newly created cluster is a new object generation.  Backups, fingerprints,
  # grades, and exam state from a deleted predecessor must never be replayed
  # into it (static control-plane manifests contain generation-specific IPs).
  for state_child in backup question-data status exam; do
    state_subdir_clear "$state_child" \
      || die "이전 클러스터 상태를 안전하게 정리하지 못했습니다: $state_child"
  done
  kind create cluster --image "$KIND_NODE_IMAGE" --config "$SCRIPT_DIR/kind-config.yaml" \
    || die "kind 클러스터 생성 실패"
  cluster_matches_version_lock || die "생성된 클러스터가 versions.lock.yaml과 일치하지 않습니다."
fi

# Docker daemon 재기동 시 worker가 먼저 IP를 확보하고, 다음 mutable 명령이
# control-plane과 worker2를 검증된 순서로 복구하도록 restart policy를 고정한다.
configure_cluster_restart_policies \
  || die "KIND 노드 restart policy 설정 또는 검증에 실패했습니다."

step "2/9 Calico CNI 설치 ($CALICO_VERSION)"
kctx apply -f "$CALICO_MANIFEST_URL" \
  || die "Calico 설치 실패"
info "노드 Ready 대기 중..."
kctx wait --for=condition=Ready nodes --all --timeout=300s >/dev/null || die "노드가 Ready 상태가 되지 않습니다."

step "3/9 metrics-server 설치 (kubectl top / HPA 용)"
metrics_manifest="$SETUP_TMP_DIR/metrics-server-components.yaml"
download_locked "$METRICS_SERVER_URL" "$METRICS_SERVER_MANIFEST_SHA256" "$metrics_manifest"
METRICS_SERVER_URL="$metrics_manifest"
export METRICS_SERVER_URL
addon_install_metrics_server || die "metrics-server 설치 실패"

step "4/9 ingress-nginx 설치 (kind provider)"
addon_install_ingress_nginx || die "ingress-nginx 설치 실패"

step "5/9 Gateway API CRD 설치 ($GATEWAY_API_VERSION)"
addon_install_gateway_api || die "Gateway API CRD 설치 실패"

step "6/9 helm 설치"
export PATH="$HOME/.local/bin:$PATH"
actual_helm_version="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
if [ "$actual_helm_version" = "$HELM_VERSION" ]; then
  info "lock 버전 Helm이 이미 설치되어 있습니다: $(command -v helm) ($HELM_VERSION)"
else
  case "$(uname -m)" in
    x86_64|amd64) helm_arch=amd64; helm_sha="$HELM_LINUX_AMD64_SHA256" ;;
    aarch64|arm64) helm_arch=arm64; helm_sha="$HELM_LINUX_ARM64_SHA256" ;;
    *) die "지원하지 않는 Helm 설치 아키텍처: $(uname -m)" ;;
  esac
  helm_archive="$SETUP_TMP_DIR/helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz"
  download_locked "https://get.helm.sh/helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz" \
    "$helm_sha" "$helm_archive"
  tar -xzf "$helm_archive" -C "$SETUP_TMP_DIR" \
    || die "Helm 압축 해제 실패"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$SETUP_TMP_DIR/linux-${helm_arch}/helm" "$HOME/.local/bin/helm" \
    || die "Helm 바이너리 설치 실패"
  actual_helm_version="$("$HOME/.local/bin/helm" version --template '{{.Version}}' 2>/dev/null || true)"
  [ "$actual_helm_version" = "$HELM_VERSION" ] \
    || die "설치된 Helm 버전 불일치: actual=${actual_helm_version:-unknown}, lock=$HELM_VERSION"
  info "Helm 설치 완료: $actual_helm_version"
fi

step "7/9 Cloud Provider KIND 설치·기동 ($CLOUD_PROVIDER_KIND_VERSION)"
addon_install_cloud_provider_kind || die "Cloud Provider KIND 설치 또는 시작 실패"
addon_wait_cloud_provider_kind || die "Cloud Provider KIND process readiness/version 검증 실패"

step "8/9 노드 준비: 이미지 프리로드 + 편집기 + ssh 래퍼"
# docker 29의 containerd 이미지 스토어와 'kind load docker-image'가 호환되지 않아
# 각 노드 안에서 crictl pull로 직접 받는다
for node in "${CKA_CLUSTER_NAME}-control-plane" "${CKA_CLUSTER_NAME}-worker" "${CKA_CLUSTER_NAME}-worker2"; do
  for img in "${PRELOAD_IMAGES[@]}"; do
    docker exec "$node" crictl pull "docker.io/library/$img" >/dev/null 2>&1 \
      || warn "$node에 $img 프리로드 실패 (풀이 시 원격 pull로 대체됨)"
  done
done
# kind 노드에는 편집기가 없어 ts-12 등 매니페스트 직접 수정 문제가 막힌다 (실전 노드엔 있음)
info "노드 편집기(vim·nano) 설치 중..."
installed_editors="$(install_node_editors)"
info "노드 편집기 설치 완료 (${installed_editors}개 노드 신규 설치)"

# 실전 시험은 control plane 노드의 etcdctl을 직접 쓴다 (ca-03/ca-04)
info "control plane에 etcd·etcdctl·etcdutl 설치 중..."
if install_node_etcdctl; then
  info "etcd·etcdctl·etcdutl 설치 완료"
elif node_etcdctl_ok; then
  info "etcd·etcdctl·etcdutl 이미 설치되어 있음"
else
  die "etcd·etcdctl·etcdutl 설치 실패 — ca-03/ca-04 환경이 불완전합니다."
fi

# 실전과 같은 `ssh <node>` 접속을 위해 bin/ssh 래퍼를 로그인 셸 PATH에 등록
chmod +x "$CKA_ROOT/bin/ssh" 2>/dev/null || true
if ssh_wrapper_ok; then
  if ensure_shell_path; then
    info "ssh 래퍼를 ~/.bashrc PATH에 등록했습니다 (새 셸부터 'ssh cka-worker' 사용 가능)."
  else
    info "ssh 래퍼가 이미 ~/.bashrc PATH에 등록되어 있습니다."
  fi
else
  warn "bin/ssh 래퍼를 실행할 수 없습니다 — 노드 접속은 'docker exec -it <노드> bash'로 대체하세요."
fi

step "9/9 채점용 상주 파드(cka-system/grader-client) + 대기"
addon_install_grader_client || die "grader-client 설치 실패"

info "핵심 컴포넌트 기동 대기 중..."
kctx -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null \
  || die "coredns readiness 검증 실패"
addon_wait_metrics_server || die "metrics-server readiness/version 검증 실패"
addon_wait_ingress_nginx || die "ingress-nginx readiness/version 검증 실패"
addon_wait_gateway_api || die "Gateway API readiness/version 검증 실패"
addon_wait_grader_client || die "grader-client readiness/version 검증 실패"

mkdir -p "$CKA_WORK_DIR"

printf '\n'
ok "클러스터 준비 완료."
kctx get nodes
printf '\n%s\n' "다음 단계:  ./cka list        # 문제 목록"
printf '%s\n'   "           ./cka start st-01 # 첫 문제 시작"
