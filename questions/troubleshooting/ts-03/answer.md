# ts-03 정답지 — Service has no endpoints (selector mismatch)

## 진단 과정

```bash
# 1. 엔드포인트가 비어 있는지부터 확인 — 서비스 불통 진단의 출발점
kubectl -n production get endpointslices
#   web-svc용 slice에 주소 없음 (또는 slice 자체가 비어 있음)

# 2. Service selector와 Pod 라벨 비교
kubectl -n production get svc web-svc -o jsonpath='{.spec.selector}'
#   {"app":"webapp"}        ← selector
kubectl -n production get pods --show-labels | head -4
#   app=web-app             ← 실제 Pod 라벨 (하이픈 차이!)
```

## 모범 답안

```bash
kubectl -n production patch svc web-svc --type=merge \
  -p '{"spec":{"selector":{"app":"web-app"}}}'
# 또는 kubectl -n production edit svc web-svc 로 selector 수정

# 확인
kubectl -n production get endpointslices    # Pod IP 3개
```

## 해설 (한국어)

- **"엔드포인트가 비었다" = selector 불일치(또는 Pod not-ready)**. Service는
  selector로 Pod를 동적으로 찾으므로, 철자 하나(webapp vs web-app)만 달라도
  아무 Pod도 매칭되지 않는다.
- 문제가 "Do NOT modify the Deployment"라고 못박았으므로 Pod 라벨을 바꾸는 방향은
  오답이다 — **어느 쪽을 고치라는 제약**을 반드시 확인할 것.
- selector는 등호 매칭이며 Service에는 matchExpressions가 없다(Deployment와 다름).
- 검증 습관: 수정 후 `get endpointslices`로 주소가 채워졌는지, 임시 Pod에서
  wget/curl로 실제 응답이 오는지 확인.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | selector 수정 | jsonpath |
| 2 | 엔드포인트 3개 | EndpointSlice 집계 |
| 1 | Deployment 무변경 | 3/3 + 라벨 확인 |
| 2 | HTTP 실측 성공 | 상주 채점 Pod에서 wget |
