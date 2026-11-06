Solve this question on: `cka-use-context ex-ca-07`

Besides the default handler `runc`, the container runtime (containerd) on the
nodes is configured with one more runtime handler for isolated workloads.

1. Find the name of that additional runtime handler in the containerd
   configuration of the node `cka-worker`.
2. Create a RuntimeClass named `sandboxed` that:
   - uses that handler
   - declares a fixed Pod overhead of `100m` CPU and `64Mi` memory
   - restricts Pods that use it to the node `cka-worker` (use the node label
     `kubernetes.io/hostname`)
3. Change the Deployment `untrusted-runner` in namespace `sandbox-lab` to use
   the RuntimeClass `sandboxed`. Both replicas must become `Ready`.

Do not add a node selector or affinity to the Deployment itself, and do not
change any node.

To open a shell on a node in this lab, use
`kubectl debug node/<node-name> -it --image=busybox:1.36 -- chroot /host bash`.
