Solve this question on: `kubectl config use-context kind-cka`

The team `alpha` needs persistent storage for its application.

1. Create a PersistentVolume named `pv-alpha` with the following specification:
   - Capacity: `2Gi`
   - Access mode: `ReadWriteOnce`
   - Volume type: `hostPath` at path `/data/pv-alpha`
   - StorageClass name: `manual`
   - Reclaim policy: `Retain`

2. Create a PersistentVolumeClaim named `pvc-alpha` in namespace `project-alpha`:
   - Request: `1Gi`
   - Access mode: `ReadWriteOnce`
   - StorageClass name: `manual`

The PVC must successfully bind to the PersistentVolume `pv-alpha`.
