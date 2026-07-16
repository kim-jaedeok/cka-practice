Solve this question on: `kubectl config use-context kind-cka`

In namespace `project-gamma` there is an existing PersistentVolumeClaim named
`cache-pvc` (currently `1Gi`) used by the Pod `cache-pod`.

The application needs more disk space:

1. Expand the PersistentVolumeClaim `cache-pvc` to request `3Gi`.
2. Do NOT delete or recreate the PVC or the Pod.

Note: the storage backend may take time to reflect the new size in `status.capacity`;
only the requested size is evaluated.
