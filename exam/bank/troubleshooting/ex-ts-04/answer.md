# ex-ts-04 정답지 — Some requests to a Service fail

## 진단 과정

```bash
kubectl -n storefront get svc shop-svc -o jsonpath='{.spec.selector}'   # {"app":"shop"}
kubectl -n storefront get pods -l app=shop -o wide --show-labels
#   shop-web-...    app=shop,track=stable
#   shop-canary-... app=shop,track=canary   ← 같은 selector에 걸린다
kubectl -n storefront get endpointslices -l kubernetes.io/service-name=shop-svc
#   endpoint 3개 (shop-web 2 + shop-canary 1)
kubectl -n storefront run probe --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do wget -qO- -T 3 http://shop-svc; done'
#   일부 요청이 503 "shop-canary not released"
```

## 모범 답안

```bash
kubectl -n storefront patch svc shop-svc --type=merge \
  -p '{"spec":{"selector":{"app":"shop","track":"stable"}}}'
kubectl -n storefront get endpointslices -l kubernetes.io/service-name=shop-svc
```

다른 정답: canary의 Pod label `app`을 다른 값(예: `shop-canary`)으로 바꾼다. Deployment
selector는 바꿀 수 없으므로 canary Deployment를 다시 만든다. canary를 0으로 scale하거나
지우면 요구사항 4를 어긴다.

## 해설

- **Service selector는 label의 부분 집합 일치다.** selector에 없는 label(`track`)은 보지
  않는다. 같은 `app` label을 쓰는 다른 workload가 있으면 그 Pod도 endpoint가 된다.
- **증상의 특징**: endpoint가 없거나(selector 불일치) port가 틀리면 모든 요청이 실패한다.
  일부 요청만 실패하면 endpoint 중 일부만 잘못된 경우를 먼저 의심한다.
- kube-proxy는 ready endpoint 중 하나를 고른다. canary Pod도 Ready이므로 트래픽을 받는다.

공식 문서:
[Service](https://kubernetes.io/docs/concepts/services-networking/service/) ·
[Labels and Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/) ·
[Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 3 | `shop-svc`의 ready endpoint가 정확히 `shop-web` Pod 2개 |
| 1 | `shop-web` 무변경, 2개 replica Ready |
| 1 | `shop-canary` 1개 replica Ready |
| 2 | 상주 채점 Pod에서 8회 연속 요청이 모두 `shop-web` 응답 |
