Solve this question on: `cka-use-context ex-ts-10`

A tenant was offboarded and its namespace `tenant-old` was deleted. The
namespace has been in the `Terminating` state ever since. The queue controller
that used to run in this cluster was uninstalled earlier, but its
CustomResourceDefinition `workqueues.queue.example.io` is still in use by
other tenants.

1. Find out what keeps `tenant-old` from being deleted.
2. Complete the deletion of `tenant-old` so that none of its objects is left
   behind in the cluster.
3. Do not delete the CustomResourceDefinition, and do not change anything in
   other namespaces, for example the WorkQueue `billing-q` in `tenant-live`.
