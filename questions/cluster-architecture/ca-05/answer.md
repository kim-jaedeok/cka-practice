# ca-05 정답지 — Drain a node for maintenance

## 모범 답안

```bash
kubectl drain cka-worker --ignore-daemonsets --delete-emptydir-data

# 확인
kubectl get nodes                        # cka-worker: Ready,SchedulingDisabled
kubectl get pods -n upkeep -o wide       # 4개 모두 다른 노드에서 Running
```

## 해설 (한국어)

- **drain = cordon + evict**: 노드를 unschedulable로 만들고(cordon), 기존 Pod를
  안전하게 축출(evict)한다. 축출된 Pod는 컨트롤러(Deployment 등)가 다른 노드에
  다시 만든다.
- 필수 플래그:
  - `--ignore-daemonsets`: DaemonSet Pod(Calico, kube-proxy 등)는 축출 불가이므로
    무시해야 진행된다. 빼면 에러로 중단.
  - `--delete-emptydir-data`: emptyDir을 쓰는 Pod가 있으면 데이터 삭제를 승인해야 한다.
  - (컨트롤러 없는 bare Pod가 있으면 `--force`도 필요)
- 유지보수가 끝나면 `kubectl uncordon cka-worker`로 스케줄링을 다시 연다 —
  이 문제에서는 **하지 않는다** (unschedulable 유지가 요구사항).
- `cordon`만 하면 신규 스케줄링만 막고 기존 Pod는 남는다 — drain과의 차이를 물어보는
  문제도 나온다.
- 공식 문서 참조 경로: **Tasks → Administer a Cluster → Safely Drain a Node**.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | `.spec.unschedulable == true` | jsonpath 비교 |
| 2 | 노드에 DaemonSet 외 Pod 없음 | ownerReferences 검사 |
| 1 | maintenance-app 4/4 Ready | `.status.readyReplicas` |
