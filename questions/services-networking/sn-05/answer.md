# sn-05 정답지 — Configure Gateway API routing

## 모범 답안

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gw
  namespace: traffic
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: shop.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store-route
  namespace: traffic
spec:
  parentRefs:
    - name: main-gw          # 같은 ns이므로 name만으로 충분
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      backendRefs:
        - name: store-svc
          port: 80
```

확인:

```bash
kubectl -n traffic get gateway,httproute
kubectl -n traffic describe httproute store-route
```

## 해설 (한국어)

- **Gateway API는 Ingress의 후계자**로 2025-02 개편에서 CKA에 새로 들어온 주제다.
  역할 분리가 핵심 설계: `GatewayClass`(인프라 제공자) → `Gateway`(클러스터 운영자,
  리스너 정의) → `HTTPRoute`(앱 개발자, 라우팅 규칙).
- `HTTPRoute.spec.parentRefs`로 Gateway에 **붙이고(attach)**, `hostnames`는
  Gateway 리스너의 hostname과 **교집합이 있어야** 트래픽을 받는다.
- Ingress와 비교: path 매칭이 `matches[].path.type: PathPrefix`로 더 구조화되어 있고,
  header/method 매칭, 트래픽 분할(weight) 등도 표준 스펙으로 지원한다.
- API 그룹이 `gateway.networking.k8s.io/v1`(코어 아님)이라는 점, 즉 CRD 설치가
  선행되어야 한다는 점도 기억할 것.
- 공식 문서 참조 경로: **Concepts → Services... → Gateway API** (gateway-api.sigs.k8s.io).

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Gateway class/listener(name·protocol·port) | jsonpath 비교 |
| 1 | listener hostname | jsonpath 비교 |
| 2 | HTTPRoute parentRef + hostname | jsonpath 비교 |
| 1 | 규칙: /store PathPrefix → store-svc:80 | jsonpath 비교 |
