# sn-10 정답지 — 교차 네임스페이스 ingress와 제한된 egress

## 모범 답안

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-checkout
  namespace: sn10-checkout
spec:
  podSelector:
    matchLabels: {app: checkout}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress: []
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-ingress
  namespace: sn10-checkout
spec:
  podSelector:
    matchLabels: {app: checkout}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              cka-practice/sn-10-role: monitoring
          podSelector:
            matchLabels:
              access: monitor
      ports:
        - {protocol: TCP, port: 8080}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: sn10-checkout
spec:
  podSelector:
    matchLabels: {app: checkout}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-catalog-egress
  namespace: sn10-checkout
spec:
  podSelector:
    matchLabels: {app: checkout}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              cka-practice/sn-10-role: catalog
          podSelector:
            matchLabels:
              app: catalog
      ports:
        - {protocol: TCP, port: 8080}
```

## 핵심 해설

- 한 `NetworkPolicyPeer` 안에 `namespaceSelector`와 `podSelector`를 함께
  쓰면 두 선택자를 모두 만족하는 Pod만 선택한다.
- 반대로 `from` 또는 `to` 배열에 두 peer를 따로 쓰면 허용 대상의 합집합이
  되어 범위가 넓어진다.
- egress를 격리한 Pod가 Service 이름을 사용하려면 실제 애플리케이션 목적지뿐
  아니라 클러스터 DNS (Domain Name System)에도 egress를 허용해야 한다. 이 문제는
  UDP (User Datagram Protocol) 53과 TCP (Transmission Control Protocol) 53을
  모두 허용하도록 요구했다.
- NetworkPolicy는 Service 객체를 직접 선택하지 않는다. Service의 Endpoint가
  되는 목적지 Pod와 그 namespace를 선택한다.

공식 문서:

- [Kubernetes NetworkPolicy 개념과 선택자 동작](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [NetworkPolicy v1 API reference](https://kubernetes.io/docs/reference/kubernetes-api/networking/network-policy-v1/)
- [Kubernetes DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 1 | ingress·egress 기본 차단 정책 의미 |
| 1 | monitoring namespace + monitor Pod ingress 교집합 |
| 1 | CoreDNS UDP/TCP 53 egress |
| 1 | catalog namespace + catalog Pod egress 교집합 |
| 2 | 세 ingress 경로 실제 허용·차단 |
| 2 | DNS·catalog 허용 및 admin 실제 차단 |
