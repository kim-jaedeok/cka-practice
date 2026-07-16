Solve this question on: `kubectl config use-context kind-cka`

In namespace `dev-team` there is an existing ServiceAccount `app-reader`.

1. Create a Role named `pod-reader` in namespace `dev-team` that allows the
   verbs `get`, `list`, `watch` on the resource `pods`.

2. Create a RoleBinding named `app-reader-binding` in namespace `dev-team`
   that grants the Role `pod-reader` to the ServiceAccount `app-reader`.

The ServiceAccount must be able to read Pods in `dev-team`, but must NOT be
able to delete them or read Pods in other namespaces.
