Solve this question on: `cka-use-context ex-ts-05`

In namespace `mapping` the Deployment `geo-resolver` (2 replicas) depends on
the Service `tiles-api` in the same namespace. Its Pods are `Running` but never
become `Ready`. Other workloads in the cluster resolve Service names normally.

1. Find the root cause.
2. Fix the Deployment `geo-resolver` so that both replicas are `Ready` and its
   containers can resolve both `tiles-api` (short name) and
   `tiles-api.mapping.svc.cluster.local` through the cluster DNS service.
3. Do NOT change or remove the readiness probe of `geo-resolver`.
4. Do NOT modify the Service `tiles-api` or the Deployment `tiles`.
