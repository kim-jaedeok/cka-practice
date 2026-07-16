Solve this question on: `kubectl config use-context kind-cka`

In namespace `commerce` the Deployment `payments` serves HTTP on container
port `80` and is exposed by the Service `payments-svc` (port `80`).

Users report that requests to `payments-svc` time out.

1. Find the reason and fix the Service so that HTTP requests to
   `payments-svc.commerce.svc.cluster.local:80` succeed.
2. Do not modify the Deployment.
