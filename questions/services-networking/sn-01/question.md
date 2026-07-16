Solve this question on: `kubectl config use-context kind-cka`

In namespace `world` there is a Deployment named `europe` running nginx on
container port `80`.

1. Expose the Deployment `europe` with a Service:
   - Name: `europe-svc`
   - Type: `ClusterIP`
   - Port: `80` → targetPort `80` (TCP)

2. The Service must have healthy endpoints and HTTP requests to
   `europe-svc.world.svc.cluster.local:80` from inside the cluster must succeed.
