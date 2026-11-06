# ex-wl-05 정답지 — Process shards with an indexed Job

## 모범 답안

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: shard-indexer
  namespace: batch-shards
spec:
  completionMode: Indexed
  completions: 4
  parallelism: 2
  backoffLimitPerIndex: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: indexer
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'echo "indexed shard $JOB_COMPLETION_INDEX: $(cat /etc/shards/shard-$JOB_COMPLETION_INDEX)"'
          volumeMounts:
            - name: shards
              mountPath: /etc/shards
      volumes:
        - name: shards
          configMap:
            name: shard-map
```

```bash
kubectl apply -f job.yaml
kubectl -n batch-shards wait --for=condition=Complete job/shard-indexer
kubectl -n batch-shards get pods -L batch.kubernetes.io/job-completion-index
kubectl -n batch-shards logs -l job-name=shard-indexer --prefix
#   indexed shard 0: eu-west ... indexed shard 3: ap-south
```

## 해설

- **`completionMode: Indexed`**에서 Job은 index 0부터 `completions-1`까지 각각 성공 Pod 하나를
  요구한다. Pod는 index를 환경 변수 `JOB_COMPLETION_INDEX`, annotation·label
  `batch.kubernetes.io/job-completion-index`, hostname(`<job>-<index>`)으로 받는다.
- **`parallelism`**은 동시에 실행할 Pod 수의 상한이다.
- **`backoffLimitPerIndex`**는 index마다 재시도 한도를 따로 센다. Job 전체의 `backoffLimit`은 모든
  index의 실패를 합쳐 센다. 이 필드는 `restartPolicy: Never`가 필요하다.
- ConfigMap volume은 key마다 파일 하나를 만든다. 그래서 index로 파일 이름을 만들어 읽을 수 있다.
  `env.valueFrom.configMapKeyRef`는 key 이름이 고정이라 index별로 다른 key를 고를 수 없다.

공식 문서:
[Jobs: Completion mode](https://kubernetes.io/docs/concepts/workloads/controllers/job/#completion-mode) ·
[Jobs: Backoff limit per index](https://kubernetes.io/docs/concepts/workloads/controllers/job/#backoff-limit-per-index) ·
[Indexed Job for Parallel Processing with Static Work Assignment](https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `completionMode: Indexed`, completions 4, parallelism 2, 컨테이너 `indexer`·`busybox:1.36` |
| 1 | `backoffLimitPerIndex: 1` |
| 1 | Job이 Complete이고 succeeded 4다 |
| 2 | 실측: index 0~3의 성공 Pod가 각각 `indexed shard <index>: <region>`을 출력했다 |
