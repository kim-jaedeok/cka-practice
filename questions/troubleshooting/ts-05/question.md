Solve this question on: `kubectl config use-context kind-cka`

Node `cka-worker2` is reported as `NotReady`.

1. Investigate the node and find the root cause.
2. Fix the problem so the node returns to `Ready` state.
3. Make sure the responsible service is running **and enabled** so it
   survives a node reboot.

Lab hint: access the node with `ssh cka-worker2`. Standard tools like
`systemctl` and `journalctl` are available on the node.
