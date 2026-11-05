# ex-ts-01 정답지 — Deployment creates no Pods

## 진단 과정

```bash
kubectl -n ledger get deploy,rs,pods            # Pod가 하나도 없다
kubectl -n ledger describe rs -l app=audit-writer
#   Warning  FailedCreate  ... error looking up service account ledger/audit-sa:
#   serviceaccount "audit-sa" not found
kubectl -n ledger get sa                         # audit-sa가 없다
```

Pod가 없으므로 `describe pod`로는 원인을 볼 수 없다. Pod를 만드는 주체인 ReplicaSet의
event를 본다.

## 모범 답안

```bash
kubectl -n ledger create serviceaccount audit-sa
kubectl -n ledger rollout restart deploy/audit-writer
kubectl -n ledger rollout status deploy/audit-writer
```

`rollout restart`는 필수는 아니다. 다만 ReplicaSet controller는 실패한 sync를 점점 긴
간격으로 다시 시도한다(controller workqueue의 rate limiter. 공식 문서 출처 미확인).
실패가 오래 쌓였으면 다음 재시도까지 기다릴 수 있다. restart는 새 ReplicaSet을 만들어
바로 다시 시도하게 한다. restart는 template의
annotation만 바꾸므로 요구사항 3을 어기지 않는다.

`serviceAccountName`을 `default`로 바꾸면 Pod는 뜨지만 요구사항 3을 어긴다.

## 해설

- **ServiceAccount admission**: Pod가 지정한 ServiceAccount가 namespace에 없으면 API
  server가 Pod 생성을 거부한다. 거부된 Pod는 저장되지 않으므로 `get pods`에 아무것도
  나오지 않는다.
- **진단 순서**: Deployment → ReplicaSet → Pod 순서로 내려가며 각 controller의 event를
  본다. Pod가 없으면 문제는 Pod보다 위(ReplicaSet 생성 단계)에 있다.

공식 문서:
[Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/) ·
[Admission Control (ServiceAccount)](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#serviceaccount) ·
[Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)

## 채점 기준 (5점)

| 배점 | 검증 항목 |
|---|---|
| 1 | ServiceAccount `audit-sa` 존재 |
| 1 | Deployment의 `serviceAccountName`과 image 유지 |
| 2 | 2개 replica Ready로 rollout 완료 |
| 1 | Running Pod 모두 `audit-sa` 사용 |
