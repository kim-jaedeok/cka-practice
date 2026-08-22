# wl-08 정답지 — LimitRange and ResourceQuota admission

## 진단

```bash
kubectl -n admission-guard describe limitrange guardrails
kubectl -n admission-guard describe resourcequota team-budget
kubectl -n admission-guard describe deploy quota-web
kubectl -n admission-guard get events --sort-by=.lastTimestamp
```

기존 Pod 두 개가 각각 CPU `300m`를 요청해 quota `600m`를 모두 사용하므로 세
번째 Pod가 admission에서 거부된다. 실행 중인 old ReplicaSet Pod를 둔 채 rolling
update하면 새 Pod의 request도 quota에 더해지므로 진행이 막힐 수 있다.

## 모범 답안

```bash
kubectl -n admission-guard scale deploy/quota-web --replicas=0
kubectl -n admission-guard wait --for=delete pod -l app=quota-web --timeout=90s

kubectl -n admission-guard set resources deploy/quota-web -c nginx \
  --requests=cpu=200m,memory=128Mi \
  --limits=cpu=400m,memory=256Mi

kubectl -n admission-guard scale deploy/quota-web --replicas=3
kubectl -n admission-guard rollout status deploy/quota-web
kubectl -n admission-guard describe resourcequota team-budget
```

## 해설

- LimitRange는 개별 Container의 최소·최대값과 기본 request/limit를 admission
  시점에 적용한다.
- ResourceQuota는 namespace 전체 사용량을 제한한다. 이 문제의 최종 CPU request는
  `3 × 200m = 600m`이고, 각 Container는 LimitRange의 경계 안에 있다.
- 정책을 삭제하는 대신 workload를 정책에 맞추는 최종 상태를 채점한다.

공식 문서:

- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)

## 채점 기준 (8점)

| 배점 | 검증 항목 |
|---:|---|
| 2 | LimitRange의 min/max/default/defaultRequest 관계 |
| 1 | ResourceQuota hard limits 보존 |
| 2 | Deployment의 정확한 requests/limits |
| 2 | 3/3 Ready |
| 1 | 실제 quota used.pods 및 used.requests.cpu |
