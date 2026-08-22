Work on node `cka-worker`.

The node is `NotReady`, and the Pod `runtime-check/runtime-probe` cannot start.
The incident may involve more than one node-local subsystem.

1. Diagnose the kubelet-to-runtime path using `systemctl`, `journalctl`, and
   `crictl`.
2. Restore and permanently enable the `containerd` service and its
   CRI (Container Runtime Interface) endpoint.
3. Repair the node's CNI (Container Network Interface) configuration under `/etc/cni/net.d`. Preserve the
   original Calico configuration rather than creating an unrelated network.
4. Make `cka-worker` Ready and make `runtime-probe` Running/Ready.

This destructive lab is **individual-only** and is excluded from mock exams.
Access the node with `ssh cka-worker`.
