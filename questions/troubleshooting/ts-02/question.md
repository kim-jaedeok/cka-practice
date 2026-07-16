Solve this question on: `kubectl config use-context kind-cka`

In namespace `batch-jobs` the Deployment `worker` (2 replicas) keeps crashing
(`CrashLoopBackOff`).

1. Inspect the Pods and find out why the container exits.
2. The container is supposed to idle with the command `sleep infinity` —
   fix the Deployment accordingly.
3. Both replicas must be Running and stay up.
