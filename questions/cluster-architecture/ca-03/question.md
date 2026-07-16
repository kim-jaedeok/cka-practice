Solve this question on: `kubectl config use-context kind-cka`

Create a backup of the cluster's etcd database.

1. Using `etcdctl`, create a snapshot and save it at
   `/var/lib/etcd/snapshot-cka.db` on the control plane.
   - etcd endpoint: `https://127.0.0.1:2379`
   - CA cert: `/etc/kubernetes/pki/etcd/ca.crt`
   - server cert: `/etc/kubernetes/pki/etcd/server.crt`
   - server key: `/etc/kubernetes/pki/etcd/server.key`

2. Verify the snapshot with `etcdutl snapshot status` and save the full
   output to `~/cka/ca-03/status.txt`.

Lab hint: in this practice environment there is no SSH — `etcdctl` and
`etcdutl` are available **inside the etcd Pod**:
`kubectl -n kube-system exec etcd-cka-control-plane -- etcdctl ...`
(`/var/lib/etcd` inside the Pod is the same directory as on the node.)
