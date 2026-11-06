Solve this question on: `cka-use-context ex-ca-08`

This kubeadm cluster will get new worker nodes in rack B later today. The
operators who add them must receive a ready-to-run join command that stops
working after a few hours.

1. Create a new bootstrap token for joining worker nodes with:
   - a lifetime (TTL) of `3h`
   - the description `rack-b expansion`
   - the default usages and groups that kubeadm uses for joining nodes
2. Save the complete `kubeadm join` command for a worker node that uses this
   token, as one line, to `~/cka/ex-ca-08/join-worker.sh` on the machine you
   are working from. The command must verify the cluster CA with its public
   key hash.
3. Do not join any node, and do not delete or change existing bootstrap
   tokens.

To open a shell on a node in this lab, use
`kubectl debug node/<node-name> -it --image=busybox:1.36 -- chroot /host bash`.
`kubeadm` is installed on `cka-control-plane`.
