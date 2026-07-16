# wl-01 정답지 — Rollback a failed Deployment and scale

## 모범 답안

```bash
kubectl config use-context kind-cka

# 상태 확인: 새 ReplicaSet의 Pod가 ImagePullBackOff인 것을 확인
kubectl -n dept-x get pods
kubectl -n dept-x rollout history deploy/api-server

# 이전 revision으로 롤백
kubectl -n dept-x rollout undo deploy/api-server

# 4개로 스케일
kubectl -n dept-x scale deploy/api-server --replicas=4

# 확인
kubectl -n dept-x rollout status deploy/api-server
kubectl -n dept-x get deploy api-server        # READY 4/4
```

## 해설 (한국어)

- **진단 순서**: `get pods`로 증상(ImagePullBackOff) 확인 → `rollout history`로
  revision 목록 확인 → `rollout undo`로 직전 revision 복귀. 특정 revision으로
  돌아가려면 `--to-revision=<N>`을 쓴다.
- `rollout undo`는 **pod template만 되돌린다** — replicas 수는 건드리지 않으므로
  스케일링은 별도로 수행해야 한다.
- 롤아웃이 "막힌" 이유: 기본 RollingUpdate 전략(maxUnavailable 25%)에서는 새 Pod가
  Ready가 되기 전까지 기존 Pod를 다 죽이지 않는다. 그래서 서비스는 살아있지만
  Deployment는 진행 불가 상태가 된다.
- 확인 습관: 마지막에 반드시 `rollout status`와 `get deploy`로 READY 4/4을 확인한다.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | 이미지가 nginx:1.28로 롤백 | `.spec.template.spec.containers[0].image` |
| 1 | `.spec.replicas` == 4 | jsonpath 비교 |
| 3 | `.status.readyReplicas` == 4 | jsonpath 비교 |
