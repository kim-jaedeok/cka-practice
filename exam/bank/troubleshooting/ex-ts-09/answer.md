# ex-ts-09 정답지 — An application cannot reach its backend after an egress lockdown

## 진단 과정

```bash
kubectl -n checkout exec deploy/cart -- nslookup pricing.catalog.svc.cluster.local
#   ;; connection timed out; no servers could be reached     ← DNS부터 막혔다
kubectl -n checkout get networkpolicy cart-egress -o yaml
#   DNS rule:     namespaceSelector matchLabels name: kube-system
#   pricing rule: port 80
kubectl get namespace kube-system --show-labels
#   kubernetes.io/metadata.name=kube-system   ← name 라벨은 없다
kubectl -n catalog get svc pricing -o wide             # port 80 → targetPort 8080
```

결함은 두 개다.

1. DNS rule의 `namespaceSelector`가 `name: kube-system` 라벨을 찾는다. kube-system에는 그 라벨이
   없다. 그래서 CoreDNS로 가는 traffic이 막힌다.
2. pricing rule이 Service port `80`을 허용한다. NetworkPolicy는 Service의 DNAT 뒤 Pod로 가는
   packet을 본다. 그래서 Pod port `8080`을 허용해야 한다.

## 모범 답안

```bash
kubectl -n checkout edit networkpolicy cart-egress
```

```yaml
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: catalog
          podSelector:
            matchLabels:
              app: pricing
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl -n checkout exec deploy/cart -- wget -qO- -T 4 http://pricing.catalog.svc.cluster.local/    # pricing-ok
kubectl -n checkout exec deploy/cart -- wget -qO- -T 4 http://inventory.catalog.svc.cluster.local/  # timed out
```

다른 정답: DNS 대상을 `podSelector: {matchLabels: {k8s-app: kube-dns}}`(namespaceSelector와 함께)로
좁혀도 된다. `kube-system` namespace에 `name` 라벨을 붙이는 방법은 라벨 변경 금지 조건을 어긴다.

## 해설

- 모든 namespace에는 `kubernetes.io/metadata.name=<이름>` 라벨이 자동으로 붙는다.
  namespaceSelector에는 이 라벨을 쓰는 것이 안전하다.
- **NetworkPolicy의 port는 Pod 쪽 port다.** ClusterIP Service로 보낸 packet은 kube-proxy가 Pod IP와
  targetPort로 바꾼 뒤 정책 검사를 받는다.
- egress를 막을 때는 DNS(UDP 53, 큰 응답은 TCP 53)를 따로 열어야 이름 조회가 된다.
- 같은 rule 안의 `namespaceSelector`와 `podSelector`는 AND다. 따로 두면 OR가 되어 더 넓게 열린다.

공식 문서:
[Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) ·
[Well-Known Labels: kubernetes.io/metadata.name](https://kubernetes.io/docs/reference/labels-annotations-taints/#kubernetes-io-metadata-name) ·
[Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---|---|
| 1 | `default-deny-egress`가 그대로다 |
| 1 | kube-system·catalog·checkout namespace 라벨이 그대로다 |
| 2 | 실측: cart에서 `pricing.catalog.svc.cluster.local`이 풀린다 |
| 2 | 실측: cart에서 pricing으로 HTTP 응답을 받는다 |
| 1 | 실측: cart에서 inventory로 가는 연결이 시간 초과로 막힌다 |
| 1 | 실측: cart에서 다른 Service(ingress controller)로 가는 연결이 막힌다 |
