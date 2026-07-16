# sn-08 정답지 — Customize CoreDNS configuration

## 모범 답안

```bash
# 1. CoreDNS ConfigMap 편집
kubectl -n kube-system edit configmap coredns
```

Corefile의 서버 블록 안에 `log` 한 줄을 추가한다:

```
.:53 {
    log                # ← 추가
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa { ... }
    ...
}
```

```bash
# 2. CoreDNS 재시작 및 확인
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns

# DNS 동작 확인
kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- nslookup kubernetes.default.svc.cluster.local

# 3. DNS 서비스 IP 저장
mkdir -p ~/cka/sn-08
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' \
  > ~/cka/sn-08/dns-ip.txt
```

## 해설 (한국어)

- CoreDNS 설정은 `kube-system`의 ConfigMap `coredns` 안 **Corefile**에 있다.
  플러그인 한 줄(`log`)을 서버 블록(`.:53 { ... }`) 안에 넣으면 모든 질의가
  stdout으로 로깅되어 `kubectl logs`로 볼 수 있다.
- **ConfigMap 수정만으로는 반영되지 않는다** — CoreDNS가 파일을 다시 읽도록
  `rollout restart`가 필요하다 (reload 플러그인이 있으면 최대 수 분 내 자동 반영되지만
  시험에서는 restart가 확실하다).
- Corefile 문법이 틀리면 CoreDNS가 CrashLoopBackOff에 빠진다 — 수정 후 반드시
  `rollout status`와 실제 nslookup으로 확인하는 습관이 중요하다 (ts-06 문제 참고).
- 클러스터 DNS 서비스는 CoreDNS로 구현되어 있어도 서비스 이름은 역사적 이유로
  `kube-dns`다.
- 공식 문서 참조 경로: **Tasks → Administer a Cluster → Customizing DNS Service**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Corefile에 `log` 플러그인 존재 | ConfigMap 내용 grep |
| 1 | CoreDNS 2/2 Ready | `.status.readyReplicas` |
| 1 | DNS 조회 실측 성공 | 상주 Pod에서 nslookup |
| 2 | dns-ip.txt == kube-dns ClusterIP | 파일 내용 비교 |
