# ex-ts-06 정답지 — A node-local Pod restarts in a loop

## 진단 과정

```bash
kubectl -n edge-system get pod edge-cache-cka-worker2 -o wide     # RESTARTS가 계속 는다
kubectl -n edge-system describe pod edge-cache-cka-worker2
#   Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
#   Normal   Killing    Container cache failed liveness probe, will be restarted
kubectl -n edge-system get pod edge-cache-cka-worker2 \
  -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.mirror}{"\n"}'
#   값이 있다 → kubelet이 만든 static Pod의 mirror Pod다
```

readiness probe는 `/healthz`를 보고 통과한다. liveness probe는 `/livez`를 보는데, 서버는 이
경로를 제공하지 않는다(404). 그래서 kubelet이 컨테이너를 계속 재시작한다.

mirror Pod는 API로 고칠 수 없다. `kubectl edit`로 probe를 바꾸면 거부되고, 삭제해도 kubelet이
같은 manifest로 다시 만든다. node의 manifest를 고친다.

## 모범 답안

```bash
kubectl debug node/cka-worker2 -it --image=busybox:1.36 -- chroot /host bash
# node 안에서
grep staticPodPath /var/lib/kubelet/config.yaml        # /etc/kubernetes/manifests
vi /etc/kubernetes/manifests/edge-cache.yaml
#   livenessProbe.httpGet.path: /livez → /healthz
exit

kubectl -n edge-system get pod edge-cache-cka-worker2 -w      # 새 Pod, RESTARTS 0, 1/1
kubectl get pods -A | grep node-debugger                       # 남은 debug Pod 정리(선택)
```

kubelet은 manifest 변경을 감지하면 Pod를 새로 만든다. 그래서 RESTARTS가 0부터 다시 센다.

## 해설

- **static Pod**는 API server가 아니라 node의 kubelet이 `staticPodPath`의 파일로 관리한다.
  API에 보이는 Pod는 읽기 전용 사본(mirror Pod)이다. 이름 끝에 node 이름이 붙고,
  `kubernetes.io/config.mirror` annotation과 Node ownerReference가 있다.
- **liveness probe와 readiness probe는 따로 판단한다.** readiness가 통과해도 liveness가 실패하면
  컨테이너는 재시작된다.
- liveness probe를 지우면 재시작은 멈추지만, 서버가 멈췄을 때 kubelet이 복구하지 못한다.
  문제는 probe를 유지하라고 요구한다.
- 다른 정답: port 대신 이름 `http`를 써도 되고, `tcpSocket` probe로 바꿔도 된다. 조건은 probe가
  실제로 성공하는 것이다.

공식 문서:
[Create static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/) ·
[Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) ·
[Debugging Kubernetes Nodes With Kubectl](https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 1 | `edge-cache`가 여전히 cka-worker2 kubelet의 static Pod다 (mirror annotation, Node owner) |
| 1 | image와 command가 바뀌지 않았다 |
| 1 | liveness probe가 남아 있다 |
| 1 | 실측: liveness probe 대상이 컨테이너 안에서 응답한다 |
| 2 | Pod가 Ready이고 재시작 0회로 20초 이상 유지된다 |
