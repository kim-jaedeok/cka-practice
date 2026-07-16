Solve this question on: `kubectl config use-context kind-cka`

In namespace `sched-check` the Deployment `sched-test` was created, but all of
its Pods stay `Pending` with **no events** explaining why. Other existing Pods
keep running fine.

1. Investigate the control plane components in namespace `kube-system`
   and find the root cause.
2. Fix the problem on the control plane node so that scheduling works again.
3. The Pods of `sched-test` must become Running.

Lab hint: access the control plane with `docker exec -it cka-control-plane bash`
(in the real exam: `ssh` to the control plane node). Remember where kubelet
reads static Pod manifests from.
