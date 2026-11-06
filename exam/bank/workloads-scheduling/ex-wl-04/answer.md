# ex-wl-04 정답지 — Autoscale on CPU with a slow scale-down

## 모범 답안

```bash
# Utilization은 request 대비 비율이다. request가 없으면 계산할 수 없다.
kubectl -n api-scale set resources deploy/quote-api -c api --requests=cpu=50m
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: quote-api
  namespace: api-scale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: quote-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
```

```bash
kubectl apply -f hpa.yaml
kubectl -n api-scale get hpa quote-api -w
#   TARGETS cpu: 0%/60%, REPLICAS 2     (1~2분 뒤. 처음 잠시는 <unknown>)
kubectl -n api-scale describe hpa quote-api     # ScalingActive True
```

`kubectl autoscale deploy quote-api --min=2 --max=6 --cpu=60%`(kubectl v1.37의 flag)로 만든 뒤
`kubectl edit hpa`로 `behavior`를 넣어도 된다.

## 해설

- **CPU Utilization 목표**는 Pod의 CPU 사용량을 컨테이너 CPU **request** 합으로 나눈 비율이다.
  request가 없으면 HPA 조건이 `FailedGetResourceMetric`(missing request for cpu)이 되고 TARGETS는
  `<unknown>`이다.
- **behavior.scaleDown**: `stabilizationWindowSeconds`는 최근 이 시간 동안 계산한 추천 값 중 가장 큰
  값을 쓰게 해서 급한 축소를 막는다. `policies`의 `type: Pods, value: 1, periodSeconds: 60`은 60초에
  최대 1개씩만 줄인다.
- `minReplicas: 2`이므로 HPA는 replica를 바로 2로 올린다.
- CPU limit은 throttling을 일으킬 수 있어 문제에서 금지했다. HPA에는 request만 필요하다.

공식 문서:
[Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) ·
[HPA: Configurable scaling behavior](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#configurable-scaling-behavior) ·
[HorizontalPodAutoscaler Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 1 | HPA가 Deployment `quote-api`를 대상으로 하고 min 2, max 6이다 |
| 1 | metric이 CPU 하나이고 averageUtilization 60이다 |
| 2 | scaleDown이 stabilization 120초, policy `Pods 1 / 60초` 하나다 |
| 1 | 컨테이너에 CPU request가 있고 CPU limit이 없다 (image 그대로) |
| 2 | 실측: HPA가 CPU 사용률을 읽고(ScalingActive) Ready Pod가 2개 이상이다 |
