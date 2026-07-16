Solve this question on: `kubectl config use-context kind-cka`

In namespace `world` there is a Deployment named `asia` running nginx on
container port `80`.

1. Create a Service to expose the Deployment `asia` outside the cluster:
   - Name: `asia-svc`
   - Type: `NodePort`
   - Port: `80` → targetPort `80` (TCP)
   - NodePort: `30080`

2. The application must be reachable on port `30080` of every node.
