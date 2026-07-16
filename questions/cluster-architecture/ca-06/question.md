Solve this question on: `kubectl config use-context kind-cka`

The control plane has already been upgraded to Kubernetes `v1.36.1`.
Worker node `cka-worker2` must be prepared for its kubelet/kubeadm upgrade.

1. Make the node `cka-worker2` unschedulable and safely evict its workloads
   (ignore DaemonSets).

2. Write the exact command sequence you would run **on the node** (Debian-based,
   apt) to upgrade it to `1.36.1`, one command per line, into the file
   `~/cka/ca-06/upgrade-commands.txt`. The sequence must include at least:
   - installing the `kubeadm` package version `1.36.1-1.1`
   - running the kubeadm node upgrade command
   - installing the `kubelet` package version `1.36.1-1.1`
   - restarting the kubelet service
   - re-enabling scheduling for the node (kubectl, run from the operator machine)

Note: do NOT actually run the package upgrade in this lab (kind nodes have no
apt) — only the drain state and the command file are graded.
