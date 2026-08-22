Use `ssh cp1` and `ssh worker2` to work on the assigned hosts.

The control plane is Kubernetes `v1.35.0`. `worker2` is genuinely running the
`v1.34.0` kubelet and has these official packages installed and held:

- `kubeadm`, `kubelet`, `kubectl`: `1.34.0-1.1`

Upgrade only `worker2` to package version `1.35.0-1.1`.

1. From `cp1`, drain `worker2`, ignoring DaemonSets and deleting emptyDir data.
2. On `worker2`, use the exact offline packages in `/opt/cka/packages`:
   - upgrade `kubeadm` first and hold it again;
   - run `kubeadm upgrade node`;
   - upgrade `kubelet` and `kubectl`, hold them again, reload systemd, and
     restart kubelet;
   - keep package installation non-interactive and preserve the existing
     `/etc/default/kubelet` configuration.
3. Wait for the Node to report kubelet `v1.35.0` and Ready, then uncordon it.
4. Preserve the original Node and `payments-api` Deployment identities. The
   Deployment in namespace `node-upgrade` must return to `2/2` Ready.

Do not upgrade the control plane, recreate the Node or Deployment, or download
packages from the network.
