# ts-11 정답지 — Ingress returns 404 for a working app

## 진단 과정

```bash
# 1. 앱 자체는 정상인지 확인
kubectl -n shop run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- wget -qO- http://checkout-svc      # "checkout service ready" — 정상

# 2. Ingress 검사
kubectl -n shop describe ingress shop-ingress
#   (1) IngressClass가 비어 있음 → 어떤 컨트롤러도 이 규칙을 처리 안 함
#   (2) backend: checkout:8080 → 서비스 이름은 checkout-svc, 포트는 80
kubectl -n shop get svc                  # checkout-svc:80 확인
```

## 모범 답안

```bash
kubectl -n shop edit ingress shop-ingress
```

```yaml
spec:
  ingressClassName: nginx          # ① 추가
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: checkout-svc # ② 수정 (checkout → checkout-svc)
                port:
                  number: 80       # ② 수정 (8080 → 80)
```

확인:

```bash
curl -H "Host: shop.example.com" http://localhost:8080/   # checkout service ready
```

## 해설 (한국어)

- **Ingress 불통 진단 순서**: (1) 백엔드 Service가 직접 호출로 동작하는지 →
  (2) Ingress의 `ingressClassName` 존재 여부 → (3) backend service 이름·포트가
  실제 Service와 일치하는지 → (4) 컨트롤러 로그
  (`kubectl -n ingress-nginx logs deploy/ingress-nginx-controller`).
- `ingressClassName` 누락은 조용한 실패의 대표 사례 — 에러 없이 그냥 어떤
  컨트롤러도 규칙을 집어가지 않는다. `kubectl get ingressclass`로 사용 가능한
  클래스 이름을 확인한다.
- `describe ingress`에서 backend 옆에 `<error: service "checkout" not found>`
  같은 힌트가 표시되기도 한다.
- backend의 `port.number`는 **Service의 port**(targetPort 아님)를 가리킨다.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | ingressClassName 추가 | jsonpath |
| 2 | backend 이름/포트 수정 | jsonpath |
| 3 | Ingress 경유 실측 성공 | curl (Host 헤더) |
