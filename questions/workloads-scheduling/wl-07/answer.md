# wl-07 정답지 — Required node affinity and topology spread

## 모범 답안

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-web
  namespace: affinity-spread
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-web
  template:
    metadata:
      labels:
        app: spread-web
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: cka-practice/wl07
                    operator: In
                    values: [eligible]
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: spread-web
      containers:
        - name: nginx
          image: nginx:1.29
```

적용 및 확인:

```bash
kubectl apply -f spread-web.yaml
kubectl -n affinity-spread rollout status deploy/spread-web
kubectl -n affinity-spread get pods -l app=spread-web -o wide
```

## 해설

- required node affinity는 조건을 만족하지 않는 노드를 스케줄링 후보에서 제외한다.
- topology spread constraint는 같은 `app=spread-web` Pod 수를 hostname 도메인별로
  비교한다. 두 eligible worker와 4 replicas에서 `maxSkew: 1`이면 결과는 2/2다.
- `DoNotSchedule`은 skew 조건을 지킬 수 없는 새 Pod를 Pending으로 남긴다.

공식 문서:

- [Assigning Pods to Nodes — Node affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#node-affinity)
- [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | required node affinity의 key/operator/value 관계 |
| 2 | topology spread의 maxSkew/topologyKey/action/selector 관계 |
| 2 | Deployment 4/4 Ready |
| 2 | 실제 worker별 Pod 수 2/2 |
