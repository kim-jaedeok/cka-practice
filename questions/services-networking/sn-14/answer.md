# sn-14 정답지 — Preserve the client source IP on a NodePort Service

## 진단과 모범 답안

```bash
NODE_IP=$(kubectl get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl http://$NODE_IP:30880          # 172.18.0.4 ← node IP (SNAT됨)

kubectl -n edge get svc echo-svc -o jsonpath='{.spec.externalTrafficPolicy}'
#   Cluster

kubectl -n edge patch svc echo-svc -p '{"spec":{"externalTrafficPolicy":"Local"}}'
curl http://$NODE_IP:30880          # 172.18.0.1 ← 이 host의 IP가 그대로 보임
```

## 해설 (한국어)

- **`externalTrafficPolicy: Cluster`(기본값)**: node port로 들어온 요청을 어느 node의 Pod로든
  보낸다. 다른 node로 넘길 수 있도록 kube-proxy가 source를 node 주소로 바꾼다(SNAT). 그래서
  application은 client IP 대신 node IP를 본다.
- **`externalTrafficPolicy: Local`**: 요청을 받은 node의 Pod로만 보낸다. 다른 node로 넘기지
  않으므로 SNAT도 하지 않아 원래 client IP가 보존된다. 대신 그 node에 Pod가 없으면 packet을
  버린다. 이 저장소의 실험에서도 Pod가 없는 `cka-worker2`의 node port는 응답하지 않았다.
- **`internalTrafficPolicy`와 구분한다.** 이 설정은 클러스터 안의 Pod가 보낸 traffic에만
  적용된다. 그래서 클러스터 밖 client의 source IP 문제는 해결하지 못한다.
- **GPU 인프라와의 관계**: 추론 gateway나 rate limit, 접근 제어는 client IP를 기준으로 동작하는
  경우가 많다. 또 `Local`은 traffic이 node를 한 번 더 건너가지 않게 해 지연을 줄인다. 대신 Pod가
  고르게 퍼지지 않으면 부하도 고르지 않다.

공식 문서:
[Using Source IP](https://kubernetes.io/docs/tutorials/services/source-ip/) ·
[Service Internal Traffic Policy](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/) ·
[Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | `externalTrafficPolicy: Local` | jsonpath 비교 |
| 1 | Service가 여전히 NodePort 30880, selector `app=echo` | jsonpath 비교 |
| 1 | Deployment·ConfigMap 무변경, Pod Ready | setup 때 저장한 UID·spec 지문 비교 |
| 2 | 클러스터 밖(host)에서 보낸 요청의 client IP가 그대로 보임 | host에서 `curl`, `ip route get`의 src 주소와 비교 |
