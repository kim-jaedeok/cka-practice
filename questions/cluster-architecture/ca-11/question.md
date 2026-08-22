Use `ssh cp1`, `ssh cp2`, and `ssh cp3` to work on the assigned hosts.

The existing cluster has:

- a working `cp1` control plane reached through the TCP load balancer;
- three Ready workers and the protected `ha-survival` workload;
- blank, unjoined `cp2` and `cp3` hosts.

Extend it to a three-control-plane stacked-etcd HA cluster.

1. On `cp1`, re-upload the shared control-plane certificates and generate a
   new certificate key.
2. Generate a valid bootstrap token and discovery CA hash.
3. Join `cp2` and `cp3`, one at a time, with `kubeadm join --control-plane` and
   the certificate key. Wait for each node to become Ready before continuing.
4. Preserve the existing cluster CA, the identity of `cp1`, and Deployment
   `ha-survival/survival-web`.
5. Create ConfigMap `ha-proof` in namespace `ha-survival` with
   `data.completed: "true"`.
6. Verify three healthy etcd members and six Ready Nodes.

Do not run `kubeadm init`, replace `cp1`, or recreate the protected Deployment.
