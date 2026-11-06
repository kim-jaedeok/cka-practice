Solve this question on: `cka-use-context ex-ts-06`

In namespace `edge-system` the Pod `edge-cache-cka-worker2` serves a local
cache on node `cka-worker2`. It becomes `Ready`, but it is restarted again and
again.

1. Find the root cause.
2. Fix it so that the Pod stays `Running` and `Ready` without further restarts.
3. The Pod must keep running on `cka-worker2` under the same management as now,
   and its container must keep a liveness probe.
4. Do not change the container image or command. Do not create any other
   workload.

To open a shell on a node in this lab, use
`kubectl debug node/<node-name> -it --image=busybox:1.36 -- chroot /host bash`.
