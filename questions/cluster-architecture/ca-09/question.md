Solve this question on: `kubectl config use-context kind-cka`

A backup operator's CustomResourceDefinition is already installed in the cluster
(group `stable.example.com`).

1. Find the full name of that CRD and save the list of **all** CRD names in
   the cluster to `~/cka/ca-09/crds.txt` (one name per line).

2. Save the documentation of the custom resource's `spec` fields
   (`kubectl explain`) to `~/cka/ca-09/spec.txt`.

3. Create a custom resource of that kind:
   - Name: `db-backup`, namespace `operators`
   - `spec.source: /data`
   - `spec.schedule: "0 2 * * *"`
