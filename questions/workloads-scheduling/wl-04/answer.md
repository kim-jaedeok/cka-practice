# wl-04 정답지 — Configure liveness and readiness probes

## 모범 답안

```bash
kubectl -n dept-y edit deploy health-api
```

컨테이너 `api`에 프로브 두 개를 추가한다:

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          image: nginx:1.29
          readinessProbe:                # 추가
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:                 # 추가
            tcpSocket:
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
```

확인:

```bash
kubectl -n dept-y rollout status deploy/health-api
kubectl -n dept-y describe pod -l app=health-api | grep -A2 -E "Liveness|Readiness"
```

## 해설 (한국어)

- **readiness vs liveness**: readiness 실패 → Service 엔드포인트에서 **제외**만 된다
  (재시작 없음). liveness 실패 → kubelet이 컨테이너를 **재시작**한다.
  "self-healing"의 핵심 프리미티브다 (공식 역량: robust, self-healing deployments).
- 프로브 방식 3종: `httpGet`(HTTP 2xx/3xx), `tcpSocket`(포트 연결), `exec`(명령 종료코드 0).
  문제에서 지정한 방식을 정확히 써야 한다 — 채점은 필드 단위로 본다.
- `initialDelaySeconds`를 너무 짧게 주면 앱 기동 전에 liveness가 실패해
  **재시작 루프**에 빠질 수 있다. 실전에서는 startupProbe로 분리하는 것이 정석.
- 공식 문서 참조 경로: **Tasks → Configure Pods and Containers →
  Configure Liveness, Readiness and Startup Probes**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | readinessProbe 4개 필드 정확히 일치 | jsonpath 비교 |
| 2 | livenessProbe 3개 필드 정확히 일치 | jsonpath 비교 |
| 1 | 롤아웃 성공 (2/2) | `.status.readyReplicas` |
