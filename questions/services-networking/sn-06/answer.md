# sn-06 정답지 — Investigate cluster DNS

## 모범 답안

```bash
# 1. 테스트용 Pod 생성
kubectl -n dns-test run dns-checker --image=busybox:1.36 --command -- sleep infinity
kubectl -n dns-test wait --for=condition=Ready pod/dns-checker

# 2. nslookup 결과를 호스트 파일로 저장
mkdir -p ~/cka/sn-06
kubectl -n dns-test exec dns-checker -- nslookup web-dns.dns-test.svc.cluster.local \
  > ~/cka/sn-06/svc.txt
kubectl -n dns-test exec dns-checker -- nslookup kubernetes.default.svc.cluster.local \
  > ~/cka/sn-06/kubernetes.txt
```

## 해설 (한국어)

- **Service DNS 규칙**: `<service>.<namespace>.svc.<cluster-domain>` (기본 도메인
  `cluster.local`). Pod의 `/etc/resolv.conf`에 search 도메인이 들어 있어
  같은 ns에서는 서비스 이름만으로도 조회된다.
- `kubectl run`으로 임시 Pod를 만들 때 `--command -- sleep infinity` 패턴을 기억할 것.
  일회성 조회라면 `kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never -- nslookup <name>`도 가능하다.
- `kubectl exec pod -- cmd > file` 은 **로컬(호스트) 셸의 리다이렉션**이므로 파일은
  호스트에 생긴다 — 시험에서 "save to file" 요구사항의 표준 처리 방식이다.
- DNS가 안 될 때의 진단 순서: (1) `kubectl -n kube-system get pods -l k8s-app=kube-dns`
  (2) kube-dns 서비스/엔드포인트 확인 (3) Pod의 `/etc/resolv.conf` 확인.
- 공식 문서 참조 경로: **Concepts → Services... → DNS for Services and Pods**.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | dns-checker Pod Running | phase + 이미지 확인 |
| 2 | svc.txt에 FQDN + 실제 ClusterIP 포함 | 파일 내용 grep |
| 2 | kubernetes.txt에 FQDN + 실제 ClusterIP 포함 | 파일 내용 grep |
