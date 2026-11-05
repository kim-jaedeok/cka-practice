# ex-wl-03 정답지 — Co-locate and spread Pods with inter-Pod affinity

## 모범 답안

```bash
kubectl -n cache-tier get pods -o wide -l 'app in (web,cache)'
kubectl -n cache-tier edit deploy cache
```

```yaml
spec:
  template:
    spec:
      affinity:
        podAffinity:                                   # web Pod가 있는 node에만
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: web}
              topologyKey: kubernetes.io/hostname
        podAntiAffinity:                               # cache끼리 같은 node 금지
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: cache}
              topologyKey: kubernetes.io/hostname
```

```bash
kubectl -n cache-tier rollout status deploy/cache
kubectl -n cache-tier get pods -o wide -l 'app in (web,cache)'   # node마다 web 1 + cache 1
```

## 해설

- **podAffinity / podAntiAffinity**: "이 label을 가진 Pod가 있는(없는) topology 영역에
  배치한다"는 규칙이다. `topologyKey: kubernetes.io/hostname`이면 영역은 node 하나다.
- **required vs preferred**: `requiredDuringScheduling...`은 만족하는 node가 없으면 Pod가
  Pending으로 남는다. `preferred...`는 점수만 준다.
- **rollout과 anti-affinity**: 예약 가능한 node가 2개이고 replica가 2개면, surge Pod가
  들어갈 빈 node가 없다. 이 Deployment는 `maxSurge: 0, maxUnavailable: 1`이라 옛 Pod를
  먼저 지우고 새 Pod를 만든다. `maxSurge`가 1 이상이고 `maxUnavailable`이 0이면 새 Pod가
  Pending으로 남아 rollout이 멈출 수 있다.
- control-plane node는 `NoSchedule` taint가 있고 web Pod도 없으므로 후보가 아니다.

공식 문서:
[Assigning Pods to Nodes — Inter-pod affinity and anti-affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity) ·
[Deployments — Max Surge / Max Unavailable](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#max-surge)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | required podAffinity: `app=web` 선택, `kubernetes.io/hostname` |
| 2 | required podAntiAffinity: `app=cache` 선택, `kubernetes.io/hostname` |
| 1 | 2개 replica Ready로 rollout 완료 |
| 2 | 실제 배치: cache Pod 2개가 서로 다른 node, 각 node에 web Pod 있음 |
