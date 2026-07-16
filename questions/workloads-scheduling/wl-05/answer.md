# wl-05 정답지 — Scheduling with nodeSelector and tolerations

## 모범 답안

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ssd-app
  namespace: scheduling
spec:
  replicas: 2
  selector:
    matchLabels: {app: ssd-app}
  template:
    metadata:
      labels: {app: ssd-app}
    spec:
      nodeSelector:            # ssd 라벨이 있는 노드로만
        disktype: ssd
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: v1
kind: Pod
metadata:
  name: prod-pod
  namespace: scheduling
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker2
  tolerations:                 # taint 허용
    - key: env
      operator: Equal
      value: prod
      effect: NoSchedule
  containers:
    - name: nginx
      image: nginx:1.29
```

확인:

```bash
kubectl -n scheduling get pods -o wide   # ssd-app → cka-worker, prod-pod → cka-worker2
```

## 해설 (한국어)

- **taint와 toleration의 관계**: taint는 노드가 "거부"하는 것이고, toleration은 Pod가
  그 거부를 "용인"하는 것이다. **toleration은 배치를 강제하지 않는다** — 그래서
  cka-worker2에 확실히 올리려면 `nodeSelector`(또는 nodeAffinity)로 노드를 지정해야 한다.
  이 조합(toleration + nodeSelector)이 시험 단골 패턴이다.
- 노드 지정에는 잘 알려진 라벨 `kubernetes.io/hostname`을 쓴다.
  `kubectl get nodes --show-labels`로 확인 가능.
- `operator: Equal`은 key/value 정확 매칭, `operator: Exists`는 key만 매칭.
- nodeSelector보다 복잡한 조건(OR, In 연산 등)이 필요하면
  `affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution`을 쓴다.
- 공식 문서 참조 경로: **Concepts → Scheduling and Eviction → Taints and Tolerations /
  Assigning Pods to Nodes**.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | nodeSelector disktype=ssd | jsonpath 비교 |
| 2 | ssd-app 2개 모두 cka-worker에서 Running | `.spec.nodeName` 집계 |
| 2 | prod-pod toleration 스펙 | jsonpath 비교 |
| 2 | prod-pod가 cka-worker2에서 Running | `.spec.nodeName` + Ready |
