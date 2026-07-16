# sn-07 정답지 — Fix a Service that receives no traffic

## 진단 과정

```bash
# 1. 증상 재현
kubectl -n commerce run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- wget -qO- -T 3 http://payments-svc     # timeout

# 2. 서비스와 엔드포인트 확인
kubectl -n commerce describe svc payments-svc
#   TargetPort: 8080/TCP   ← 컨테이너는 80을 리슨하는데 8080으로 보내고 있음
kubectl -n commerce get endpointslices
#   엔드포인트 주소는 있으나 포트가 8080

# 3. 컨테이너 포트 확인
kubectl -n commerce get deploy payments -o jsonpath='{.spec.template.spec.containers[0].ports}'
#   containerPort: 80
```

## 모범 답안

```bash
kubectl -n commerce edit svc payments-svc
# spec.ports[0].targetPort: 8080 → 80
```

또는:

```bash
kubectl -n commerce patch svc payments-svc --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
```

## 해설 (한국어)

- **Service 트래픽 불통의 3대 원인**: (1) selector와 pod 라벨 불일치 → 엔드포인트가
  아예 없음, (2) `targetPort`와 컨테이너 리슨 포트 불일치 → 엔드포인트는 있지만
  연결 거부/타임아웃, (3) Pod not-ready (readinessProbe 실패) → 엔드포인트에서 제외.
  이 문제는 (2)번 케이스다.
- 진단은 `describe svc`(selector·port 요약)와 `get endpointslices`(실제 대상 IP:port)
  조합이 가장 빠르다.
- `port`(서비스 노출 포트) vs `targetPort`(컨테이너 포트) 구분은 시험 전반의 기본기다.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | targetPort == 80 | jsonpath 비교 |
| 1 | Deployment 무변경 (금지사항 준수) | containerPort/replicas 확인 |
| 2 | HTTP 실측 성공 | 상주 채점 Pod에서 wget |
