Solve this question on: `cka-use-context ex-st-03`

In namespace `reports-store` the Deployment `report-server` (container
`server`) serves report files from the volume `data`, mounted at `/data`. The
volume uses the PersistentVolumeClaim `reports-old` (`256Mi`). Its
StorageClass `standard` cannot expand volumes, so the data must move to a new,
larger claim.

1. Create a PersistentVolumeClaim `reports-v2` in namespace `reports-store`
   with StorageClass `standard`, access mode `ReadWriteOnce` and a request of
   `512Mi`.
2. Copy all files and directories from `reports-old` to `reports-v2`, keeping
   their paths and content.
3. Change the Deployment `report-server` so that its volume `data` uses
   `reports-v2`. The mount path stays `/data`. The Deployment must end with
   `1` Ready replica.
4. Keep the claim `reports-old` and its data.

You may create temporary Pods for the copy.
