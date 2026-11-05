# ex-ts-03 정답지 — Batch Job fails before producing its report

## 진단 과정

```bash
kubectl -n reports get job,pods
#   nightly-report   Failed   0/1      Pod 2개 Error
kubectl -n reports describe job nightly-report      # BackoffLimitExceeded
kubectl -n reports logs job/nightly-report
#   FATAL: settings file /etc/report/report.conf is missing (code RPT-417)
kubectl -n reports get job nightly-report -o yaml | grep -A3 volumeMounts
#   mountPath: /etc/reports   ← script는 /etc/report를 읽는다
```

## 모범 답안

```bash
# 1. Job을 지우면 실패한 Pod와 로그도 함께 지워진다. 로그를 먼저 저장한다.
kubectl -n reports logs job/nightly-report > ~/cka/ex-ts-03/job-error.log

# 2. Job의 Pod template은 바꿀 수 없다. manifest를 받아 고친 뒤 다시 만든다.
kubectl -n reports get job nightly-report -o yaml > job.yaml
#   - metadata: name, namespace만 남긴다 (uid, resourceVersion, labels 등 삭제)
#   - spec.selector와 spec.template.metadata.labels 삭제 (자동 생성 값)
#   - status 삭제
#   - volumeMounts[0].mountPath: /etc/reports → /etc/report
kubectl -n reports delete job nightly-report
kubectl apply -f job.yaml
kubectl -n reports wait --for=condition=Complete job/nightly-report --timeout=120s
kubectl -n reports logs job/nightly-report   # report generated format=csv range=24h
```

`subPath: report.conf`로 `/etc/report/report.conf`에 key 하나만 mount해도 정답이다.

## 해설

- **Job template은 immutable이다.** `kubectl edit`로 `spec.template`을 고치면 API server가
  거부한다. 지우고 다시 만든다.
- **자동 생성 selector**: `get -o yaml` 결과에는 `batch.kubernetes.io/controller-uid`
  selector와 label이 들어 있다. 그대로 다시 만들면 "`selector` not auto-generated"
  오류가 난다. 이 필드를 지우고 만든다.
- **로그 보존 순서**: Job을 지우면 Job이 소유한 Pod도 garbage collection으로 지워진다.
  실패 원인을 남겨야 하면 지우기 전에 로그를 저장한다.

공식 문서:
[Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/) ·
[Configure a Pod to Use a ConfigMap](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/) ·
[kubectl logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `job-error.log`가 오류 줄 하나만 정확히 포함 |
| 1 | ConfigMap `report-config` 무변경 |
| 1 | Job의 image와 command 유지 |
| 2 | Job `nightly-report`가 Complete |
| 1 | 성공한 Pod 로그에 ConfigMap 값이 출력됨 |
