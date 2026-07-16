Solve this question on: `kubectl config use-context kind-cka`

In namespace `data-layer`:

- PersistentVolume `report-pv` (1Gi) exists and is `Available`
- PersistentVolumeClaim `report-pvc` is stuck in `Pending`
- Pod `report-app` (uses `report-pvc`) is stuck in `Pending`

1. Find out why the PVC does not bind to the PV.
2. Fix the problem so that `report-pvc` is `Bound` to `report-pv` and
   `report-app` is `Running`.
3. Do NOT modify the PersistentVolume.

Hint: some PVC spec fields are immutable — recreating the PVC (and the Pod,
if needed) is allowed.
