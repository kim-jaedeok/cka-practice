# sn-04 정답지 — Route traffic with an Ingress

## 모범 답안

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: web-zone
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /a
            pathType: Prefix
            backend:
              service:
                name: web-a
                port:
                  number: 80
          - path: /b
            pathType: Prefix
            backend:
              service:
                name: web-b
                port:
                  number: 80
```

확인 (이 연습 환경에서는 컨트롤러가 host의 8080 포트에 노출됨):

```bash
kubectl -n web-zone get ingress web-ingress     # ADDRESS가 채워질 때까지 잠시 대기
curl -s -H "Host: app.example.com" http://localhost:8080/a/   # response from web-a
curl -s -H "Host: app.example.com" http://localhost:8080/b/   # response from web-b
```

## 해설 (한국어)

- Ingress는 **L7(HTTP) 라우팅 규칙**이고, 실제 트래픽 처리는 Ingress **컨트롤러**
  (여기서는 ingress-nginx)가 담당한다. `ingressClassName`으로 어떤 컨트롤러가
  이 규칙을 처리할지 지정한다 — 빼먹으면 어떤 컨트롤러도 처리하지 않는 것이
  대표적 실수다.
- `pathType` 3종: `Prefix`(경로 접두 매칭), `Exact`(정확 일치), `ImplementationSpecific`.
  시험에서 지정된 값을 그대로 쓸 것.
- 빠른 생성: `kubectl create ingress web-ingress --class=nginx --rule="app.example.com/a*=web-a:80" --rule="app.example.com/b*=web-b:80" -n web-zone --dry-run=client -o yaml`
  으로 골격을 만들고 수정하는 방법도 있다.
- Host 헤더 기반 라우팅이므로 테스트 시 `-H "Host: app.example.com"`이 필요하다.
- 공식 문서 참조 경로: **Concepts → Services... → Ingress**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Ingress 스펙 (class/host/path→service) | jsonpath 비교 |
| 2 | /a 실측 라우팅 | curl (Host 헤더) 본문 확인 |
| 2 | /b 실측 라우팅 | curl (Host 헤더) 본문 확인 |
