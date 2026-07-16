Solve this question on: `kubectl config use-context kind-cka`

A snapshot of etcd exists at `/var/lib/etcd/snapshot-restore-src.db` on the
control plane.

As a **restore drill**, restore this snapshot into a NEW data directory
(do NOT reconfigure the running etcd — this cluster must stay up):

1. Using `etcdutl`, restore the snapshot
   `/var/lib/etcd/snapshot-restore-src.db` into the data directory
   `/var/lib/etcd/restore-drill`.

2. Verify the restored directory contains the etcd member structure
   (`member/snap`, `member/wal`).

Lab hint: run `etcdutl` inside the etcd Pod
(`kubectl -n kube-system exec etcd-cka-control-plane -- etcdutl ...`).
In the real exam you would do this over SSH on the node — the command is
identical.
