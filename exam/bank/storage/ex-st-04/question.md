Solve this question on: `cka-use-context ex-st-04`

Sensor data must be stored on the local disk of node `cka-worker2` only. The
cluster's local volume provisioner is `rancher.io/local-path` (it also serves
the StorageClass `standard`).

1. Create a StorageClass `edge-local` that:
   - uses the provisioner `rancher.io/local-path`
   - delays binding and provisioning until a Pod uses the claim
   - allows volumes to be provisioned only on `cka-worker2` (use the node
     label `kubernetes.io/hostname`)
   - is not the default StorageClass. `standard` must stay the default.
2. In namespace `edge-data`, create a PersistentVolumeClaim `sensor-cache`
   with StorageClass `edge-local`, access mode `ReadWriteOnce` and a request
   of `128Mi`.
3. In namespace `edge-data`, create a Pod `sensor-writer` with image
   `busybox:1.36` that mounts `sensor-cache` at `/cache` and keeps running.

The Pod must end up on `cka-worker2` only because of the StorageClass. Do not
set `nodeName`, a node selector or affinity on the Pod.
