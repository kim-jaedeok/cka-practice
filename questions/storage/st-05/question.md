Solve this question on: `kubectl config use-context kind-cka`

Namespace `storage-lifecycle` contains Pod `archive-writer` using PVC `archive-old`,
which is bound to the static PV `archive-pv`. The Pod has written the file
`/archive/marker.txt` with the content `cka-retained-data`.

Migrate the claim without losing that data:

1. Change `archive-pv` to reclaim policy `Retain`. It must use only the
   `ReadWriteOnce` access mode.
2. Delete the old consumer Pod and PVC `archive-old`, then make the released PV
   available for a replacement claim. Do not delete or recreate `archive-pv`.
3. Create PVC `archive-restored` in `storage-lifecycle`:
   - `storageClassName: archive-lifecycle`
   - `volumeName: archive-pv`
   - request `1Gi`
   - access mode `ReadWriteOnce`
4. Create Pod `archive-reader`, image `busybox:1.36`, on node `cka-worker`.
   Mount `archive-restored` at `/archive` and keep the Pod running.

The replacement claim must bind to the original PV, `archive-reader` must be
Ready, and `/archive/marker.txt` must still contain `cka-retained-data`.
