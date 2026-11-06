# ex-ts-07 정답지 — A worker container keeps getting killed

## 진단 과정

```bash
kubectl -n media-proc get pods -l app=thumbnailer            # RESTARTS가 는다, CrashLoopBackOff
kubectl -n media-proc describe pod -l app=thumbnailer
#   Last State:  Terminated
#     Reason:    OOMKilled
#     Exit Code: 137
#   Limits:   memory: 64Mi
kubectl -n media-proc get deploy thumbnailer \
  -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}'
#   80,000,000 byte 버퍼를 shell 변수로 메모리에 올린다
```

`OOMKilled`는 컨테이너가 memory limit을 넘어서 kernel이 프로세스를 죽였다는 뜻이다. 명령은
80 MB를 메모리에 올리는데 limit은 64Mi다. limit을 올려야 한다.

## 모범 답안

```bash
kubectl -n media-proc set resources deploy/thumbnailer -c worker --limits=memory=192Mi
kubectl -n media-proc rollout status deploy/thumbnailer
kubectl -n media-proc logs deploy/thumbnailer          # frame buffer ready (80000000 bytes)
kubectl -n media-proc get pods -l app=thumbnailer      # RESTARTS 0
```

`128Mi`로는 부족하다. shell이 문자열을 만드는 동안 버퍼 크기보다 메모리를 더 쓰기 때문이다.
`128Mi`에서 다시 OOMKilled가 나면 limit을 더 올린다. 문제의 상한은 `256Mi`다.

## 해설

- **memory limit**: 컨테이너가 limit을 넘으면 kernel OOM killer가 프로세스를 죽인다. kubelet은
  종료 이유를 `OOMKilled`, 종료 코드를 137(128 + SIGKILL 9)로 보고한다.
- **request와 limit은 역할이 다르다.** request는 scheduler가 node를 고를 때 쓰고, limit은 실행 중
  사용량의 상한이다. 이 문제는 request를 바꾸지 말라고 한다.
- limit을 지우면 재시작은 멈추지만, 컨테이너가 node 메모리를 제한 없이 쓸 수 있다. 문제는
  limit 유지를 요구한다.
- `kubectl top pod`(metrics-server)로 실제 사용량을 보고 limit을 정할 수 있다.

공식 문서:
[Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) ·
[Assign Memory Resources to Containers and Pods](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | image와 command가 바뀌지 않았다 |
| 1 | memory request가 여전히 32Mi다 |
| 1 | memory limit이 있고 256Mi 이하다 |
| 2 | Pod 1개가 Ready이고 재시작 0회로 15초 이상 유지된다 |
| 1 | 실측: 컨테이너가 버퍼를 다 올렸다는 로그를 남겼다 |
