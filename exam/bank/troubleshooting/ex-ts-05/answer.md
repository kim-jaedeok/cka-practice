# ex-ts-05 정답지 — Pods never become Ready after a DNS change

## 진단 과정

```bash
kubectl -n mapping get pods -l app=geo-resolver          # Running, READY 0/1
kubectl -n mapping describe pod -l app=geo-resolver | grep -i readiness
#   Readiness probe failed: ... connection timed out; no servers could be reached
kubectl -n mapping exec deploy/geo-resolver -- cat /etc/resolv.conf
#   nameserver 192.0.2.53      ← cluster DNS가 아니다
kubectl -n mapping get deploy geo-resolver -o jsonpath='{.spec.template.spec.dnsPolicy}'
#   None
kubectl -n kube-system get svc kube-dns                   # cluster DNS의 ClusterIP
```

다른 workload는 정상이므로 CoreDNS 장애가 아니다. 이 Pod의 DNS 설정만 의심한다.

## 모범 답안

```bash
kubectl -n mapping edit deploy geo-resolver
#   spec.template.spec.dnsPolicy: None → ClusterFirst
#   spec.template.spec.dnsConfig 블록 삭제
kubectl -n mapping rollout status deploy/geo-resolver
kubectl -n mapping exec deploy/geo-resolver -- nslookup tiles-api.mapping.svc.cluster.local
```

다른 정답: `dnsPolicy: None`을 유지하고 `dnsConfig.nameservers`를 kube-dns ClusterIP로,
`searches`를 `mapping.svc.cluster.local svc.cluster.local cluster.local`로 바꾼다.
search 목록이 없으면 short name `tiles-api`가 풀리지 않는다.

readiness probe를 지우면 Pod는 Ready가 되지만 DNS는 여전히 실패한다(요구사항 3 위반).

## 해설

- **dnsPolicy**: `ClusterFirst`(기본값)는 kubelet이 kube-dns ClusterIP와 namespace search
  domain으로 `/etc/resolv.conf`를 만든다. `None`은 `dnsConfig`만 사용한다.
- **증상 범위로 원인을 좁힌다**: 한 workload만 이름을 못 풀면 그 Pod의 DNS 설정을 본다.
  모든 Pod가 못 풀면 CoreDNS나 kube-dns Service를 본다.

공식 문서:
[DNS for Services and Pods — Pod's DNS Policy](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-s-dns-policy) ·
[Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | readiness probe 무변경 |
| 1 | Service `tiles-api`와 Deployment `tiles` 무변경 |
| 2 | 2개 replica Ready로 rollout 완료 |
| 2 | 모든 Pod가 kube-dns를 nameserver로 쓰고 short name·FQDN으로 `tiles-api`에 접근 |
