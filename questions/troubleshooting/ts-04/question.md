Solve this question on: `kubectl config use-context kind-cka`

In namespace `heavy` the Deployment `bigmem` (2 replicas) shows all Pods
stuck in `Pending`.

1. Find out why the scheduler cannot place the Pods.
2. The application actually needs only `64Mi` of memory and `50m` CPU per Pod.
   Adjust the Deployment's resource **requests** accordingly
   (set the limits to `128Mi` / `200m`).
3. Both replicas must become Ready.
