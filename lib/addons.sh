#!/usr/bin/env bash
# 클러스터 애드온 설치·점검 단일 소스.
# setup-cluster.sh(최초 설치), cka cluster doctor(점검·복구),
# require_cluster(문제 시작 전 자동 자가치유)에서 공통으로 사용한다.
#
# 여기서 다루는 애드온은 "클러스터 생성 후 원격 매니페스트로 얹는" 취약 계층이다.
# (coredns·StorageClass는 노드 이미지 내장, Calico는 setup-cluster.sh가 직접 관리)
#
# 모든 install 함수는 kubectl apply 기반이라 멱등하다 — 이미 정상이어도 재호출은
# 무해(unchanged)하므로, 점검이 애매하면 그냥 install을 불러도 안전하다.

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.0}"
METRICS_SERVER_URL="${METRICS_SERVER_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
INGRESS_NGINX_URL="${INGRESS_NGINX_URL:-https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml}"

# 자가치유 대상 애드온 목록 (순서 = 점검·복구 순서). "key|사람이 읽는 이름"
CKA_ADDONS=(
  "metrics_server|metrics-server (kubectl top / HPA)"
  "ingress_nginx|ingress-nginx + IngressClass/nginx"
  "gateway_api|Gateway API CRD + GatewayClass/nginx"
  "grader_client|cka-system/grader-client (채점용)"
)

# ── metrics-server ───────────────────────────────────────────────
addon_ok_metrics_server() {
  kctx -n kube-system get deploy metrics-server >/dev/null 2>&1
}
addon_install_metrics_server() {
  kctx apply -f "$METRICS_SERVER_URL" || return 1
  # kind는 kubelet 인증서가 자체서명이라 --kubelet-insecure-tls 필요 (중복 적용 방지)
  if ! kctx -n kube-system get deploy metrics-server \
      -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q kubelet-insecure-tls; then
    kctx -n kube-system patch deployment metrics-server --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
      >/dev/null 2>&1 || warn "metrics-server patch 실패"
  fi
}

# ── ingress-nginx ────────────────────────────────────────────────
# IngressClass와 컨트롤러 Deployment가 모두 있어야 정상으로 본다.
addon_ok_ingress_nginx() {
  kctx get ingressclass nginx >/dev/null 2>&1 \
    && kctx -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1
}
addon_install_ingress_nginx() {
  kctx apply -f "$INGRESS_NGINX_URL" || return 1
  # 컨트롤러를 control-plane(ingress-ready, hostPort 80→호스트 8080 매핑 노드)에 고정.
  # 이 patch가 빠지면 IngressClass가 있어도 curl localhost:8080 실측이 실패한다.
  kctx -n ingress-nginx patch deploy ingress-nginx-controller --type=strategic -p '{
    "spec":{"template":{"spec":{
      "nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"},
      "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]
    }}}}' >/dev/null 2>&1 || warn "ingress-nginx nodeSelector patch 실패"
}

# ── Gateway API ──────────────────────────────────────────────────
# CRD가 있어야 gatewayclass 리소스 타입이 존재하고, 그 위에 GatewayClass/nginx.
addon_ok_gateway_api() {
  kctx get gatewayclass nginx >/dev/null 2>&1
}
addon_install_gateway_api() {
  kctx apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" \
    || return 1
  # 문제에서 참조할 GatewayClass (컨트롤러는 두지 않음 — 스펙 작성 연습용)
  kctx apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: example.com/nginx-gateway-controller
EOF
}

# ── 채점용 상주 파드 ─────────────────────────────────────────────
addon_ok_grader_client() {
  kctx -n cka-system get deploy grader-client >/dev/null 2>&1
}
addon_install_grader_client() {
  kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cka-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grader-client
  namespace: cka-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: grader-client}
  template:
    metadata:
      labels: {app: grader-client}
    spec:
      containers:
        - name: client
          image: busybox:1.36
          command: ["sleep", "infinity"]
EOF
}

# 빠진 애드온만 재설치. 조용히 동작하고, 실제로 복구한 개수를 반환(exit code 아님, echo).
# 사용: repaired=$(ensure_addons); [ "$repaired" -gt 0 ] && ...
ensure_addons() {
  local entry key human repaired=0
  for entry in "${CKA_ADDONS[@]}"; do
    key="${entry%%|*}"
    human="${entry#*|}"
    if ! "addon_ok_$key"; then
      info "자가치유: $human 재설치 중..." >&2
      if "addon_install_$key" >/dev/null 2>&1; then
        repaired=$((repaired + 1))
      else
        warn "$human 재설치 실패 — 'cka cluster up' 을 직접 실행해 보세요." >&2
      fi
    fi
  done
  printf '%s' "$repaired"
}
