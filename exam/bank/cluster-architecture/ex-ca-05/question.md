Solve this question on: `cka-use-context ex-ca-05`

The cutover plan for a cluster upgrade was just stored in the ConfigMap
`cutover-plan` in namespace `upgrade-prep`. Before the upgrade starts, the
cluster's etcd database must be backed up.

1. On the control plane node `cka-control-plane`, use `etcdctl` to save a
   snapshot of the running etcd member to
   `/var/lib/etcd-backup/pre-upgrade.db`. The backup must contain the
   ConfigMap `cutover-plan`.
   - Connect to the member's local client endpoint over TLS. The CA,
     certificate and key paths are not given here: take them from the etcd
     member's own configuration on the node.
2. Save the revision number of this snapshot (only the number) to
   `~/cka/ex-ca-05/revision.txt` on the machine you are working from.
3. Do not change the etcd configuration. etcd must keep running.

To open a shell on a node in this lab, use
`kubectl debug node/<node-name> -it --image=busybox:1.36 -- chroot /host bash`.
`etcdctl` and `etcdutl` are installed on `cka-control-plane`.
