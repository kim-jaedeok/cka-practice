Solve this question on: `kubectl config use-context kind-cka`

In namespace `node-agents`, the Pod `legacy-agent` runs on node `cka-worker`
with `hostNetwork: true` and serves HTTP on the node's port `9180`.

A new Pod `metrics-exporter` must also run on `cka-worker` with
`hostNetwork: true`, but it stays `Pending`.

1. Find out why `metrics-exporter` is `Pending`.
2. Make `metrics-exporter` run and become `Ready` on `cka-worker`, still with
   `hostNetwork: true`, serving the same content on the node's port `9181`.
   Declare the port it uses in the Pod spec.
3. Do NOT modify or delete `legacy-agent`. It must keep serving on port `9180`.
