Solve this question on: `kubectl config use-context kind-cka`

In namespace `production` the Deployment `web-app` (3 replicas) is healthy,
but the Service `web-svc` returns connection errors — it routes no traffic.

1. Find the root cause.
2. Fix the **Service** so that requests to
   `web-svc.production.svc.cluster.local:80` reach the `web-app` Pods.
3. Do NOT modify the Deployment.
