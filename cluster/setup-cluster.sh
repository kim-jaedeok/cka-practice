#!/usr/bin/env bash
# CKA 연습 클러스터 셋업: kind 3노드 + Calico + metrics-server + ingress-nginx
# + Gateway API CRD + helm + 이미지 프리로드 + ssh 래퍼 + 채점용 상주 파드
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CALICO_VERSION="v3.32.1"
GATEWAY_API_VERSION="v1.6.0"
PRELOAD_IMAGES=(nginx:1.28 nginx:1.29 busybox:1.36)

step() { printf '\n%s\n' "${C_BLD}── $* ──${C_RST}"; }

for bin in docker kind kubectl curl; do
  command -v "$bin" >/dev/null || die "$bin 이 설치되어 있지 않습니다."
done
docker info >/dev/null 2>&1 || die "docker 데몬에 연결할 수 없습니다."

step "1/8 kind 클러스터 생성 (name: $CKA_CLUSTER_NAME)"
if kind get clusters 2>/dev/null | grep -qx "$CKA_CLUSTER_NAME"; then
  info "클러스터가 이미 존재합니다. 생성 단계는 건너뜁니다."
else
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml" || die "kind 클러스터 생성 실패"
fi

# WSL 재시작 시 컨테이너가 자동 복구되도록 restart 정책 강화
docker update --restart=unless-stopped \
  "${CKA_CLUSTER_NAME}-control-plane" "${CKA_CLUSTER_NAME}-worker" "${CKA_CLUSTER_NAME}-worker2" \
  >/dev/null 2>&1 || true

step "2/8 Calico CNI 설치 ($CALICO_VERSION)"
kctx apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" \
  || die "Calico 설치 실패"
info "노드 Ready 대기 중..."
kctx wait --for=condition=Ready nodes --all --timeout=300s >/dev/null || die "노드가 Ready 상태가 되지 않습니다."

step "3/8 metrics-server 설치 (kubectl top / HPA 용)"
addon_install_metrics_server || die "metrics-server 설치 실패"

step "4/8 ingress-nginx 설치 (kind provider)"
addon_install_ingress_nginx || die "ingress-nginx 설치 실패"

step "5/8 Gateway API CRD 설치 ($GATEWAY_API_VERSION)"
addon_install_gateway_api || die "Gateway API CRD 설치 실패"

step "6/8 helm 설치"
export PATH="$HOME/.local/bin:$PATH"
if command -v helm >/dev/null; then
  info "helm이 이미 설치되어 있습니다: $(command -v helm)"
else
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO=false PATH="$HOME/.local/bin:$PATH" bash \
    || true  # 설치 스크립트의 마지막 verify가 PATH 문제로 실패할 수 있어 바이너리로 직접 확인
  [ -x "$HOME/.local/bin/helm" ] || command -v helm >/dev/null || die "helm 설치 실패"
  info "helm 설치 완료: $("$HOME/.local/bin/helm" version --short 2>/dev/null || echo ok)"
fi

step "7/8 노드 준비: 이미지 프리로드 + 편집기 + etcdctl + ssh 래퍼"
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

# 실전 노드에는 etcdctl이 깔려 있다 — ca-03/ca-04를 Pod exec 우회 없이 풀 수 있게
info "control-plane 노드에 etcdctl·etcdutl 설치 중..."
if [ "$(install_node_etcdctl)" -gt 0 ]; then
  info "etcdctl·etcdutl 설치 완료"
else
  info "etcdctl·etcdutl 이미 존재하거나 설치를 건너뛰었습니다"
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

step "8/8 채점용 상주 파드(cka-system/grader-client) + 대기"
addon_install_grader_client || die "grader-client 설치 실패"

info "핵심 컴포넌트 기동 대기 중..."
kctx -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null || warn "coredns 대기 시간 초과"
kctx -n kube-system rollout status deploy/metrics-server --timeout=180s >/dev/null || warn "metrics-server 대기 시간 초과"
kctx -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s >/dev/null || warn "ingress-nginx 대기 시간 초과"
kctx -n cka-system rollout status deploy/grader-client --timeout=180s >/dev/null || warn "grader-client 대기 시간 초과"

mkdir -p "$CKA_WORK_DIR"

printf '\n'
ok "클러스터 준비 완료."
kctx get nodes
printf '\n%s\n' "다음 단계:  ./cka list        # 문제 목록"
printf '%s\n'   "           ./cka start st-01 # 첫 문제 시작"
