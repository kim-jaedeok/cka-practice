Solve this question on: `kubectl config use-context kind-cka`

Node `cka-worker` requires hardware maintenance.

1. Safely evict all workloads from node `cka-worker`
   (ignore DaemonSet-managed Pods; delete Pods using emptyDir data if needed).
2. The node must remain **unschedulable** afterwards.
3. The Deployment `maintenance-app` in namespace `upkeep` must keep running
   with all 4 replicas (they will move to other nodes).

Do NOT delete or restart the node itself.
