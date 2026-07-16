Solve this question on: `kubectl config use-context kind-cka`

A monitoring tool running as ServiceAccount `node-inspector` in namespace
`dev-team` needs read access to cluster nodes.

1. Create a ClusterRole named `node-viewer` that allows the verbs
   `get`, `list` on the resource `nodes`.

2. Create a ClusterRoleBinding named `node-viewer-binding` that grants the
   ClusterRole `node-viewer` to the ServiceAccount `node-inspector` in
   namespace `dev-team`.

The ServiceAccount must be able to list nodes, but must NOT be able to
delete nodes or list secrets.
