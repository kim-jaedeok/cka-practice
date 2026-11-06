# ex-sn-06 정답지 — Point an existing Service name at a service in another namespace

## 모범 답안

```bash
kubectl -n shop-frontend delete svc payments
kubectl -n shop-frontend create service externalname payments \
  --external-name payments-api.payments-core.svc.cluster.local
kubectl -n shop-frontend delete deploy payments-legacy

kubectl -n shop-frontend get svc payments          # TYPE ExternalName, EXTERNAL-IP payments-api.payments-core...
kubectl -n shop-frontend exec deploy/web-client -- nslookup payments
#   payments.shop-frontend.svc.cluster.local  canonical name = payments-api.payments-core.svc.cluster.local
kubectl -n shop-frontend exec deploy/web-client -- wget -qO- http://payments:8080/    # payments-api v2
```

다른 정답: Service를 지우지 않고 한 번에 바꾼다. `type`을 `ExternalName`으로 바꿀 때
`clusterIP`, `clusterIPs`를 함께 지워야 API가 받아 준다. 쓰이지 않는 `selector`도 함께 지운다.

```bash
kubectl -n shop-frontend patch svc payments --type=merge -p '{"spec":{
  "type":"ExternalName","externalName":"payments-api.payments-core.svc.cluster.local",
  "selector":null,"clusterIP":null,"clusterIPs":null}}'
```

## 해설

- **ExternalName Service**는 cluster IP와 endpoint가 없다. selector가 있어도 쓰이지 않는다
  (`kubectl create service externalname`은 `app=<이름>` selector를 넣는다). CoreDNS가 Service 이름에 대해
  `externalName` 값으로 CNAME record를 돌려준다. kube-proxy는 관여하지 않는다.
- **FQDN을 써야 한다.** `externalName: payments-api`라고 쓰면 CNAME 대상이 `payments-api.`가 되어
  search 경로 없이 풀리지 않는다.
- **port는 바뀌지 않는다.** client는 `payments:8080`으로 접속하고, CNAME으로 얻은
  `payments-api`의 ClusterIP의 같은 port 8080으로 간다. 두 Service의 port가 같아서 동작한다.
- HTTP의 `Host` header는 원래 이름(`payments`)으로 남는다. Host 기반으로 라우팅하는 backend에서는
  문제가 될 수 있다.

공식 문서:
[Service: type ExternalName](https://kubernetes.io/docs/concepts/services-networking/service/#externalname) ·
[DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `payments`가 `ExternalName`이고 `payments-api.payments-core.svc.cluster.local`을 가리킨다 |
| 1 | `payments-legacy` Deployment와 Pod가 없다 |
| 2 | 실측: web-client에서 `http://payments:8080/` 요청에 `payments-api v2`가 답한다 |
| 1 | `payments-core`의 Deployment와 Service가 setup 때와 같다 |
