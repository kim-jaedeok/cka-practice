# ex-wl-01 정답지 — Roll out a new image with a zero-downtime strategy

## 모범 답안

```bash
kubectl -n orders patch deploy order-api --type=merge -p '{
  "spec": {"revisionHistoryLimit": 5,
           "strategy": {"type": "RollingUpdate",
                        "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}}}'
kubectl -n orders set image deploy/order-api api=nginx:1.29
kubectl -n orders annotate deploy/order-api kubernetes.io/change-cause="upgrade nginx to 1.29" --overwrite
kubectl -n orders rollout status deploy/order-api
kubectl -n orders rollout history deploy/order-api
#   REVISION  CHANGE-CAUSE
#   1         <none>
#   2         upgrade nginx to 1.29
```

strategy를 image보다 먼저 바꾼다. 그래야 image 변경으로 시작하는 rollout이 처음부터 새
strategy로 진행된다.

## 해설

- **maxSurge / maxUnavailable**: `maxUnavailable: 0`이면 새 Pod가 Ready가 되어야 옛 Pod를
  줄인다. `maxSurge: 1`이면 desired보다 Pod를 1개까지 더 만든다. 둘 다 0이면 rollout이
  진행할 수 없으므로 API server가 거부한다.
- **change-cause**: `rollout history`의 CHANGE-CAUSE 열은 ReplicaSet의
  `kubernetes.io/change-cause` annotation이다. Deployment의 annotation은 새
  ReplicaSet에 복사된다. 그래서 annotation은 image 변경 직후에 달아도 된다(이 저장소의
  selftest로 확인한 동작이다).
- **revisionHistoryLimit**: 남겨 둘 옛 ReplicaSet 수다. 0이면 rollback할 수 없다.

공식 문서:
[Deployments — Rolling Update Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment) ·
[Deployments — Checking Rollout History](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#checking-rollout-history-of-a-deployment) ·
[Well-Known Labels, Annotations and Taints — kubernetes.io/change-cause](https://kubernetes.io/docs/reference/labels-annotations-taints/#change-cause)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 1 | RollingUpdate, maxSurge 1, maxUnavailable 0 |
| 1 | revisionHistoryLimit 5 |
| 1 | image `nginx:1.29` |
| 2 | 최신 revision ReplicaSet이 `nginx:1.29`이고 change-cause 일치 |
| 2 | 4개 replica Ready로 rollout 완료 |
