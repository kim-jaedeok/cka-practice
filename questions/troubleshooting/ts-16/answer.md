# ts-16 정답지 — Service has endpoints that never become ready

## 진단 과정

```bash
# 1. 증상 재현
kubectl -n inventory run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- wget -qO- -T 3 http://stock-svc        # 실패

# 2. Pod 상태: Running이지만 READY 0/1
kubectl -n inventory get pods -l app=stock-api

# 3. EndpointSlice: 주소는 있지만 ready=false
kubectl -n inventory get endpointslices -l kubernetes.io/service-name=stock-svc -o yaml
#   conditions: {ready: false, serving: false, terminating: false}

# 4. 왜 ready가 아닌가
kubectl -n inventory describe pod -l app=stock-api
#   Readiness probe failed: HTTP probe failed with statuscode: 404
kubectl -n inventory get deploy stock-api \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'
#   path: /healthz  ← nginx 기본 이미지에는 이 경로가 없다
```

## 모범 답안

```bash
kubectl -n inventory patch deploy stock-api --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
kubectl -n inventory rollout status deploy/stock-api
```

`/healthz`를 그대로 두고 nginx가 그 경로를 응답하게 만들어도 된다. 예를 들어 ConfigMap의
파일을 `/usr/share/nginx/html/healthz`에 mount한다. probe를 지우면 트래픽은 흐르지만
요구사항 3을 어긴다.

## 해설 (한국어)

- **Service는 ready인 endpoint로만 트래픽을 보낸다.** Pod가 Running이어도 readiness probe가
  실패하면 EndpointSlice의 endpoint는 `ready: false`가 된다. kube-proxy는 이 endpoint를
  backend로 쓰지 않는다.
- **진단 순서**: `get pods`의 READY 열 → `get endpointslices`의 `conditions.ready` →
  `describe pod`의 probe 실패 이벤트. selector 불일치(`ts-03`)는 endpoint가 아예 없고,
  targetPort 불일치(`sn-07`)는 endpoint가 ready인데 연결이 실패한다. 이 문제는 endpoint가
  있지만 ready가 아닌 세 번째 경우다.
- **GPU 인프라와의 관계**: 분산 학습 job이나 추론 서버는 model을 다 올리기 전까지 요청을
  받으면 안 된다. readiness probe가 그 기준이고, EndpointSlice의 ready 조건이 실제 전달
  여부를 정한다.

공식 문서:
[Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/) ·
[Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/) ·
[EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) ·
[Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | HTTP readiness probe가 port 80으로 남아 있음 | Deployment JSON 검사 |
| 1 | Service 무변경 | setup 때 저장한 UID·spec 지문 비교 |
| 1 | 2개 Pod Ready로 rollout 완료 | Deployment status |
| 2 | ready endpoint와 HTTP 실측 성공 | EndpointSlice와 상주 채점 Pod의 wget |
