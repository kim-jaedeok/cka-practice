Solve this question on: `kubectl config use-context kind-cka`

In namespace `edge`, the Deployment `echo` runs one Pod on node `cka-worker`.
It answers every HTTP request with the client IP address it sees. The Service
`echo-svc` exposes it on node port `30880`.

Clients outside the cluster call `http://<cka-worker InternalIP>:30880`, but the
application reports a node IP instead of the client's own IP.

1. Configure the Service `echo-svc` so that the application sees the original
   client source IP for requests that arrive through the node port.
2. Keep the Service type `NodePort` and node port `30880`.
3. Do NOT modify the Deployment or its ConfigMap.
