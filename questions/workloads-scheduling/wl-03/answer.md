# wl-03 정답지 — Configure a HorizontalPodAutoscaler

## 모범 답안

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-cache-hpa
  namespace: autoscale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-cache
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

확인:

```bash
kubectl -n autoscale get hpa web-cache-hpa
kubectl -n autoscale get deploy web-cache     # 잠시 후 READY 2/2
```

## 해설 (한국어)

- HPA 이름이 지정된 문제에서는 `kubectl autoscale` 명령보다 **YAML로 작성**하는 것이
  안전하다 (`kubectl autoscale deploy web-cache ...`는 HPA 이름이 Deployment와 같은
  `web-cache`로 만들어져 요구사항 위반).
- `autoscaling/v2`가 현행 표준 API다. v2에서는 `metrics[]` 배열로 CPU 외에 메모리·
  커스텀 메트릭도 지정할 수 있다. `targetCPUUtilizationPercentage`는 구버전(v1) 필드.
- HPA가 동작하려면 (1) **metrics-server**가 설치되어 있고, (2) 대상 Pod에
  **resources.requests.cpu**가 정의되어 있어야 한다 — 사용률(%)의 분모가 requests다.
- 현재 replicas(1)가 minReplicas(2)보다 작으므로 HPA 컨트롤러가 곧 2로 올린다.
  반영에 15~30초 걸릴 수 있다.
- 공식 문서 참조 경로: **Tasks → Run Applications → Horizontal Pod Autoscaling**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | HPA 존재 + scaleTargetRef가 web-cache | jsonpath 비교 |
| 2 | minReplicas 2 / maxReplicas 5 | jsonpath 비교 |
| 1 | CPU Utilization 60% 메트릭 | jsonpath 비교 |
| 1 | Deployment가 2개로 스케일됨 | `.status.readyReplicas` |
