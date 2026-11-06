# ex-ts-08 정답지 — A scheduled maintenance job stopped running

## 진단 과정

```bash
kubectl -n nightly-ops get cronjob db-vacuum
#   SUSPEND False, ACTIVE 1, LAST SCHEDULE이 오래됐거나 없다
kubectl -n nightly-ops describe cronjob db-vacuum
#   Concurrency Policy: Forbid
#   Active Jobs:        <멈춘-Job>
#   Warning  JobAlreadyActive  Not starting job because prior execution is running ...
kubectl -n nightly-ops get jobs,pods
kubectl -n nightly-ops logs job/<멈춘-Job>
#   waiting for lock on table orders     ← 끝나지 않는 실행
```

`concurrencyPolicy: Forbid`는 이전 실행이 끝나지 않았으면 새 실행을 건너뛴다. 멈춘 Job 하나가
active로 남아 있어 모든 새 실행이 막혔다.

## 모범 답안

```bash
# 1. 앞으로 만들 Job에 deadline을 준다 (Job spec 필드)
kubectl -n nightly-ops patch cronjob db-vacuum --type=merge \
  -p '{"spec":{"jobTemplate":{"spec":{"activeDeadlineSeconds":120}}}}'

# 2. 멈춘 Job을 지운다
kubectl -n nightly-ops delete job <멈춘-Job>

# 3. 바로 확인하려면 CronJob에서 Job을 하나 만든다 (기다리면 1분 안에 예약 실행도 된다)
kubectl -n nightly-ops create job --from=cronjob/db-vacuum db-vacuum-manual
kubectl -n nightly-ops wait --for=condition=Complete job/db-vacuum-manual
kubectl -n nightly-ops logs job/db-vacuum-manual       # vacuum complete
```

다른 정답: 멈춘 Job을 지우는 대신 `kubectl patch job <멈춘-Job> -p
'{"spec":{"activeDeadlineSeconds":1}}'`로 끝낼 수 있다. Job이 `DeadlineExceeded`로 Failed가 되면
CronJob이 다음 예약 시각에 새 Job을 만든다.

## 해설

- **`activeDeadlineSeconds`**는 Job spec 필드다. 시간이 지나면 Job controller가 실행 중인 Pod를
  끝내고 Job을 `Failed`(reason `DeadlineExceeded`)로 바꾼다. CronJob에서는
  `spec.jobTemplate.spec.activeDeadlineSeconds`에 둔다.
- **`startingDeadlineSeconds`와 다르다.** 이 CronJob 필드는 놓친 예약을 얼마나 늦게까지
  시작할지만 정한다. 실행 중인 Job을 멈추지 않는다.
- **concurrencyPolicy**: `Allow`(기본)는 겹쳐 실행하고, `Forbid`는 새 실행을 건너뛰고,
  `Replace`는 이전 실행을 지우고 새로 시작한다. 문제는 `Forbid` 유지를 요구한다.
- `kubectl create job --from=cronjob/...`로 만든 Job도 CronJob을 ownerReference로 가진다.

공식 문서:
[CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) ·
[Jobs: Job termination and cleanup](https://kubernetes.io/docs/concepts/workloads/controllers/job/#job-termination-and-cleanup)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | CronJob의 schedule·concurrencyPolicy·suspend·컨테이너가 그대로다 |
| 1 | 멈춘 Job이 더 이상 실행 중이 아니다 (삭제 또는 종료) |
| 2 | `jobTemplate.spec.activeDeadlineSeconds`가 1~120이다 |
| 2 | CronJob `db-vacuum`에서 나온 새 Job이 Complete다 |
