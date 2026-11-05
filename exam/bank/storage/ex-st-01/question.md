Solve this question on: `cka-use-context ex-st-01`

Three PersistentVolumes with the StorageClass name `archive` exist:
`archive-pv-a`, `archive-pv-b` and `archive-pv-c`. Their labels describe the
storage tier (`tier`) and the media type (`media`).

1. In namespace `vault-archive`, create a PersistentVolumeClaim `vault-claim`
   with StorageClass `archive`, access mode `ReadWriteOnce` and a request of
   `1Gi`. It must bind to the PersistentVolume that has **both**
   `tier=cold` and `media=ssd`. Select the volume with a label selector on the
   claim. Do not set `volumeName`.
2. The data on that PersistentVolume must survive when the claim is deleted.
   Make sure the volume's reclaim policy allows this.
3. Create a Pod `vault-writer` in namespace `vault-archive` with image
   `busybox:1.36` that mounts `vault-claim` at `/vault`, writes the text
   `sealed` to `/vault/state.txt`, and then keeps running.
