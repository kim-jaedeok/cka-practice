# ex-wl-06 정답지 — Canary one StatefulSet replica with a partitioned update

## 모범 답안

순서가 중요하다. partition을 **먼저** 건다.

```bash
kubectl -n quorum patch sts kv -p \
  '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'
kubectl -n quorum set image sts/kv kv=nginx:1.29
kubectl -n quorum rollout status sts/kv
kubectl -n quorum get pods -L controller-revision-hash \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,RESTARTS:.status.containerStatuses[0].restartCount
#   kv-0  nginx:1.28  0
#   kv-1  nginx:1.28  0
#   kv-2  nginx:1.29  0
```

## 해설

- **`rollingUpdate.partition: N`**이면 controller는 ordinal이 N 이상인 Pod만 새 revision으로
  바꾼다. ordinal이 N보다 작은 Pod는 template이 바뀌어도 그대로 둔다. 이 Pod가 지워지면 이전
  revision으로 다시 만든다.
- **image를 먼저 바꾸면 안 된다.** partition이 0인 상태에서 template을 바꾸면 controller가 가장 큰
  ordinal부터 Pod를 바꾸기 시작한다. 그 사이 `kv-1`이 교체될 수 있다.
- canary 확인 뒤 전체 반영은 `partition`을 0으로 낮추면 된다.
- `kubectl rollout status sts/kv`는 partition이 있으면 partition 이상 Pod의 갱신까지만 기다린다.

공식 문서:
[StatefulSets: Partitioned rolling updates](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#partitions) ·
[StatefulSet Basics: Staging an update](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/#staging-an-update)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | updateStrategy가 RollingUpdate이고 partition이 2다 |
| 1 | Pod template image가 `nginx:1.29`다 |
| 2 | `kv-2`가 새 revision(`updateRevision`)이고 `nginx:1.29`로 Ready다 |
| 2 | `kv-0`, `kv-1`이 setup 때와 같은 Pod(UID)이고 재시작 0회, `nginx:1.28`로 Ready다 |
