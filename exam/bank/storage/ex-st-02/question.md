Solve this question on: `cka-use-context ex-st-02`

In namespace `render-farm` the Deployment `renderer` (2 replicas, container
`worker`) writes temporary frames to a volume named `scratch` mounted at
`/scratch`. Today `scratch` is an `emptyDir`, which uses the node's root disk.

Replace the `scratch` volume so that:

1. Each Pod gets its own PersistentVolumeClaim, created automatically from a
   claim template inside the Pod spec, and deleted automatically together with
   the Pod.
2. The claims use StorageClass `standard`, access mode `ReadWriteOnce`, and
   request `256Mi`.
3. The volume keeps the name `scratch` and the mount path `/scratch`.
4. `renderer` finishes its rollout with `2` Ready replicas.

Do not create PersistentVolumeClaims yourself.
