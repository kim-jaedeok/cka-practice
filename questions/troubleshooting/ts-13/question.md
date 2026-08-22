Work on the control-plane node `cka-control-plane`.

The Kubernetes API (Application Programming Interface) is unavailable. Both the local etcd static Pod and the
`kube-apiserver` static Pod were changed shortly before the outage.

1. Use node-local tools such as `crictl` and the kubelet logs to diagnose the
   failure. Do not reset the cluster or replace the etcd data directory.
2. Restore the etcd client listener to its original secure loopback endpoint
   `https://127.0.0.1:2379`.
3. Restore the API server etcd endpoint to `https://127.0.0.1:2379`.
4. Verify that etcd is healthy, both static Pods are Ready, and the Kubernetes
   API `/readyz` endpoint returns success.

This destructive lab is **individual-only** and is excluded from mock exams.
Access the node with `ssh cka-control-plane`.
