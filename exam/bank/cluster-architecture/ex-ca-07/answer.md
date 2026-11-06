# ex-ca-07 정답지 — Run a workload under a second container runtime handler

## 모범 답안

```bash
kubectl debug node/cka-worker -it --image=busybox:1.36 -- chroot /host bash
# node 안에서
grep -n 'runtimes\.' /etc/containerd/config.toml
#   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
#   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.test-handler]
crictl info | grep -A1 '"runtimes"'        # 같은 정보를 CRI로 확인할 수도 있다
exit
```

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: sandboxed
handler: test-handler
overhead:
  podFixed:
    cpu: 100m
    memory: 64Mi
scheduling:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
```

```bash
kubectl apply -f runtimeclass.yaml
kubectl -n sandbox-lab patch deploy untrusted-runner \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"sandboxed"}}}}'
kubectl -n sandbox-lab rollout status deploy/untrusted-runner
kubectl -n sandbox-lab get pods -o wide                                   # 모두 cka-worker
kubectl -n sandbox-lab get pod <pod> -o jsonpath='{.spec.overhead}{"\n"}'  # {"cpu":"100m","memory":"64Mi"}
```

## 해설

- **RuntimeClass**는 Pod를 어떤 CRI runtime handler로 실행할지 고른다. `handler`는 node의 CRI
  설정에 있는 이름과 같아야 한다. 없는 이름을 쓰면 sandbox 생성이 실패하고 Pod가
  `ContainerCreating`에 머문다.
- **overhead**: RuntimeClass admission이 Pod 생성 시 `spec.overhead`를 넣는다. scheduler와
  ResourceQuota는 컨테이너 request에 이 값을 더해 계산한다. 이미 있는 Pod에는 넣지 않으므로
  Deployment rollout으로 새 Pod를 만든다.
- **scheduling.nodeSelector**: admission이 RuntimeClass의 nodeSelector를 Pod의 nodeSelector에
  합친다. 그래서 Deployment에 직접 nodeSelector를 넣지 않아도 Pod가 `cka-worker`에만 놓인다.
- `handler`는 생성 뒤에 바꿀 수 없다. 잘못 만들었으면 RuntimeClass를 지우고 다시 만든다.

공식 문서:
[Runtime Class](https://kubernetes.io/docs/concepts/containers/runtime-class/) ·
[Pod Overhead](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/) ·
[Debugging Kubernetes Nodes With Kubectl](https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | RuntimeClass `sandboxed`의 handler가 `test-handler`다 |
| 1 | overhead.podFixed가 cpu 100m, memory 64Mi다 |
| 1 | scheduling.nodeSelector가 `kubernetes.io/hostname: cka-worker`다 |
| 2 | Deployment가 `runtimeClassName: sandboxed`이고 Ready 2개다 |
| 1 | 실측: 두 Pod가 cka-worker에서 overhead와 함께 `test-handler`로 실행된다 (crictl) |
