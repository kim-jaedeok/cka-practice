Solve this question on: `kubectl config use-context kind-cka`

In namespace `dept-y` the Deployment `health-api` (container `api`, nginx) has
no health checks configured. Make the Deployment self-healing:

1. Add a **readinessProbe** to the container `api`:
   - `httpGet` on path `/` port `80`
   - `initialDelaySeconds: 5`, `periodSeconds: 10`

2. Add a **livenessProbe** to the container `api`:
   - `tcpSocket` on port `80`
   - `initialDelaySeconds: 15`, `periodSeconds: 20`

3. The Deployment must roll out successfully (2/2 replicas ready).
