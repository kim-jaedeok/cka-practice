Solve this question on: `cka-use-context ex-ca-01`

The platform team wants to store backup policies as Kubernetes objects.

1. Create a CustomResourceDefinition for the API group
   `dataprotection.example.org` with:
   - kind `BackupPolicy`, plural `backuppolicies`, singular `backuppolicy`,
     short name `bkp`
   - scope `Namespaced`
   - one version `v1`, served and used as the storage version
   - an OpenAPI schema in which `spec` is required and has these fields:
     - `schedule`: string, **required**
     - `retentionDays`: integer, minimum `1`, maximum `90`
     - `target`: string
   - an additional printer column `Schedule` that shows `.spec.schedule`
2. In namespace `backup-ops`, create a `BackupPolicy` named `nightly-db` with
   `schedule: "0 2 * * *"`, `retentionDays: 14`, and `target: orders-db`.

The API server must reject a `BackupPolicy` without `spec.schedule` and one
with `retentionDays: 120`.
