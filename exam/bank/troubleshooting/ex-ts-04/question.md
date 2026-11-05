Solve this question on: `cka-use-context ex-ts-04`

In namespace `storefront` the Service `shop-svc` exposes the Deployment
`shop-web` on port `80`. Users report that some requests to
`shop-svc.storefront.svc.cluster.local` return HTTP `503`, while others work.

1. Find the root cause.
2. Fix it so that every request to `shop-svc.storefront.svc.cluster.local:80`
   is answered by a `shop-web` Pod.
3. Do NOT modify the Deployment `shop-web`.
4. The Deployment `shop-canary` must stay in the namespace with `1` Ready
   replica. It will be exposed through its own Service later.
