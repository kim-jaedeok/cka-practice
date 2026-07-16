Solve this question on: `kubectl config use-context kind-cka`

In namespace `ci-cd` a pipeline runs as ServiceAccount `deployer` and reports
errors like:

```
deployments.apps is forbidden: User "system:serviceaccount:ci-cd:deployer"
cannot list resource "deployments" in API group "apps" in the namespace "ci-cd"
```

A Role `deployer-role` and a RoleBinding `deployer-binding` already exist in
namespace `ci-cd`, but the Role grants the wrong permissions.

Fix the Role `deployer-role` so the ServiceAccount can `get`, `list` and
`update` **Deployments** (API group `apps`) in namespace `ci-cd`.
The ServiceAccount must NOT be able to delete Deployments.
