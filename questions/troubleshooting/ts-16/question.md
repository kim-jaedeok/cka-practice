Solve this question on: `kubectl config use-context kind-cka`

In namespace `inventory` the Deployment `stock-api` (2 replicas) is exposed by
the Service `stock-svc` on port `80`. Both Pods are `Running`, but requests to
`stock-svc.inventory.svc.cluster.local:80` fail.

1. Find the root cause.
2. Fix it so that HTTP requests to `stock-svc.inventory.svc.cluster.local:80`
   succeed and both Pods are `Ready`.
3. Keep an HTTP readiness probe on port `80` in the Deployment. Do not remove
   the probe.
4. Do NOT modify the Service.
