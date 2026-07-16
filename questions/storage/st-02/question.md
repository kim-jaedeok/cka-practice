Solve this question on: `kubectl config use-context kind-cka`

1. Create a new StorageClass named `fast-storage` with the following specification:
   - Provisioner: `rancher.io/local-path`
   - Volume binding mode: `WaitForFirstConsumer`
   - Reclaim policy: `Delete`

2. In namespace `project-beta`, create a PersistentVolumeClaim named `data-fast`:
   - Request: `500Mi`
   - Access mode: `ReadWriteOnce`
   - StorageClass: `fast-storage`

3. In namespace `project-beta`, create a Pod named `web-fast` using image `nginx:1.29`
   that mounts the PVC `data-fast` at `/usr/share/nginx/html`.

The PVC must be bound and the Pod must be running.
