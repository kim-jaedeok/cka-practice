The application in namespace `service-chain` has three symptoms:

- Service `web-service` has no usable backends.
- One `kube-proxy` Pod is not Ready after a configuration incident.
- Deployment `cni-probe` cannot create a working Pod on `cka-worker2` because
  its CNI (Container Network Interface) layer is damaged.

Repair every layer without changing the application image or replacing the
cluster:

1. Make `web-service` select the two Pods labelled `app=web` on port 80.
2. Restore kube-proxy's kubeconfig path to
   `/var/lib/kube-proxy/kubeconfig.conf`, then make the DaemonSet fully Ready.
3. Restore the original Calico CNI configuration on `cka-worker2`.
4. Make `cni-probe` Ready and verify that `service-client` can read
   `service-chain-ok` from `http://web-service`.

This destructive lab is **individual-only** and is excluded from mock exams.
