# ex-sn-02 정답지 — Route two hosts and an exact path through one Ingress

## 모범 답안

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: portal, namespace: docs-portal}
spec:
  ingressClassName: nginx
  rules:
    - host: docs.portal.test
      http:
        paths:
          - path: /status
            pathType: Exact
            backend: {service: {name: status-page, port: {number: 80}}}
          - path: /
            pathType: Prefix
            backend: {service: {name: docs-v2, port: {number: 80}}}
    - host: legacy.portal.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: {service: {name: docs-v1, port: {number: 80}}}
```

```bash
kubectl apply -f portal.yaml
kubectl -n docs-portal run probe --image=busybox:1.36 --rm -it --restart=Never -- sh -c '
  C=http://ingress-nginx-controller.ingress-nginx.svc.cluster.local
  wget -qO- --header "Host: docs.portal.test"   $C/status          # status
  wget -qO- --header "Host: docs.portal.test"   $C/status/history  # docs v2
  wget -qO- --header "Host: legacy.portal.test" $C/                # docs v1'
```

`kubectl create ingress`로도 만들 수 있다. 예:
`--rule="docs.portal.test/status=status-page:80" --rule="docs.portal.test/*=docs-v2:80"`.
공식 문서에 따르면 path에 `*`가 있으면 `pathType: Prefix`가 된다. `*`가 없을 때의 값은
문서에 적혀 있지 않으므로 `kubectl get ingress -o yaml`로 `Exact`인지 확인한다.

## 해설

- **pathType**: `Exact`는 경로 전체가 같아야 일치한다. `Prefix`는 `/`로 나눈 경로
  요소 단위로 앞부분이 같으면 일치한다. 그래서 `Prefix /status`는 `/status/history`도
  잡는다.
- **우선순위**: 여러 path가 일치하면 가장 긴 path가 이긴다. 길이가 같으면 `Exact`가
  `Prefix`보다 우선한다.
- **host 기반 분기**: rule마다 `host`를 둔다. controller는 요청의 `Host` header로
  rule을 고른다.

공식 문서:
[Ingress — Path types and examples](https://kubernetes.io/docs/concepts/services-networking/ingress/#path-types) ·
[Ingress — Name based virtual hosting](https://kubernetes.io/docs/concepts/services-networking/ingress/#name-based-virtual-hosting) ·
[kubectl create ingress](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_ingress/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | IngressClass `nginx` 사용 |
| 2 | `docs.portal.test/` → `docs-v2` (controller 경유 실측) |
| 1 | `legacy.portal.test/` → `docs-v1` |
| 2 | `/status` → `status-page`, `/status/history` → `docs-v2` |
