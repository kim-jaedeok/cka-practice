Use `ssh cp1`, `ssh worker1`, and `ssh worker2` to work on the assigned hosts.

The three hosts contain containerd, kubelet, kubeadm, and cached images, but do
not contain Kubernetes cluster state. Build the cluster from this blank state.

1. On `cp1`, inspect and validate `/opt/cka/kubeadm-init.yaml`, then use it to
   initialize the Kubernetes v1.35 control plane. It fixes the Pod CIDR at
   `10.244.0.0/16`, includes API server certificate SAN `127.0.0.1`, and
   contains the local runtime compatibility settings for this disposable cell.
2. Configure `/root/.kube/config` on `cp1` and install the local network add-on
   from `/opt/cka/kindnet.yaml`. Do not download a manifest.
3. Join `worker1` and `worker2` to the cluster with kubeadm.
4. Create namespace `bootstrap-check` containing:
   - Deployment `bootstrap-web`, image `nginx:1.29`, two Ready replicas;
   - one `bootstrap-web` Pod on each worker;
   - Service `bootstrap-web`, selecting only those Pods, port `80`;
   - Pod `network-client`, image `busybox:1.36`, kept running on a worker.
5. Verify that `network-client` can retrieve `http://bootstrap-web`.

Do not initialize another control plane and do not use the shared `kind-cka`
cluster.
