# ts-04 정답지 — Pods stuck in Pending (insufficient resources)

## 진단 과정

```bash
kubectl -n heavy get pods
#   bigmem-xxx   0/1   Pending

kubectl -n heavy describe pod <pod> | tail -8
#   Warning  FailedScheduling ... 0/3 nodes are available:
#   ... Insufficient memory, Insufficient cpu ...

kubectl -n heavy get deploy bigmem \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
#   requests: memory 100Gi, cpu 30   ← 노드 용량 초과
```

## 모범 답안

```bash
kubectl -n heavy edit deploy bigmem
```

```yaml
          resources:
            requests:
              memory: 64Mi
              cpu: 50m
            limits:
              memory: 128Mi
              cpu: 200m
```

```bash
kubectl -n heavy rollout status deploy/bigmem   # 2/2
```

## 해설 (한국어)

- **Pending 진단 루틴**: Pending은 "스케줄러가 놓을 노드를 못 찾음"이다.
  `describe pod`의 `FailedScheduling` 이벤트에 정확한 이유가 나온다:
  Insufficient cpu/memory, node affinity 불일치, taint 미용인, PVC 미바인딩 등.
- requests는 **스케줄링 기준**(노드의 allocatable에서 차감), limits는 **런타임 상한**
  (CPU는 스로틀, 메모리는 초과 시 OOMKill). 노드 가용량은
  `kubectl describe node <node>`의 Allocatable/Allocated resources에서 확인.
- Deployment의 template을 고치면 롤링 업데이트로 새 Pod가 만들어지며 Pending Pod는
  자동 정리된다.
- 참고: 네임스페이스에 LimitRange/ResourceQuota가 있으면 그 제약도 Pending/생성거부의
  원인이 될 수 있다 — `kubectl get limitrange,resourcequota -n <ns>`도 확인 습관.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | requests 64Mi/50m | jsonpath |
| 1 | limits 128Mi/200m | jsonpath |
| 3 | 2/2 Ready | `.status.readyReplicas` |
