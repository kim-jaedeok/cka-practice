# ts-06 정답지 — Cluster-wide DNS failure (CoreDNS broken)

## 진단 과정

```bash
# 1. DNS 컴포넌트 상태
kubectl -n kube-system get pods -l k8s-app=kube-dns
#   coredns-xxx   0/1   CrashLoopBackOff

# 2. 왜 죽는지 로그 확인
kubectl -n kube-system logs -l k8s-app=kube-dns --previous 2>/dev/null | tail -5
#   ... Error during parsing: Unknown directive 'forwardx' ...

# 3. 설정 확인
kubectl -n kube-system get cm coredns -o yaml | grep forwardx
#   forwardx . /etc/resolv.conf ...      ← 오타
```

## 모범 답안

```bash
kubectl -n kube-system edit cm coredns
# 'forwardx' → 'forward' 로 수정

kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns   # 2/2

# DNS 동작 확인
kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- nslookup kubernetes.default.svc.cluster.local
```

## 해설 (한국어)

- **클러스터 전역 DNS 장애 → CoreDNS부터 본다**: `kube-system`에서
  `-l k8s-app=kube-dns` 라벨로 Pod 상태 확인이 1순위.
- CrashLoopBackOff이면 `logs --previous`가 결정적 단서를 준다 — CoreDNS는
  Corefile 파싱 실패 시 정확히 어느 directive가 문제인지 로그에 남긴다
  ("Unknown directive").
- ConfigMap 수정 후 **rollout restart 필수** — Pod가 죽어 있어도 ConfigMap을
  자동으로 다시 읽지 않는다.
- 이 유형의 변형: kube-dns Service의 selector 변조, coredns Deployment replicas 0,
  Pod의 dnsPolicy 오류 등 — 모두 "Pod → Service/EndpointSlice → 설정" 순서로 추적한다.
- 공식 문서 참조 경로: **Tasks → Administer a Cluster →
  Debugging DNS Resolution**.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Corefile 오타 수정 | ConfigMap grep |
| 3 | CoreDNS 2/2 Ready | `.status.readyReplicas` |
| 2 | DNS 실측 성공 | 상주 Pod에서 nslookup |
