Solve this question on: `kubectl config use-context kind-cka`

A distributed job in namespace `training` needs each worker Pod to have a
stable DNS name that other workers can resolve.

1. Create a **headless** Service named `workers` in namespace `training` that
   selects Pods with label `app=worker` and exposes port `80`.
2. Create a StatefulSet named `worker` in namespace `training`:
   - 2 replicas, Pod label `app=worker`
   - container image `nginx:1.29`, container port `80`
   - use the Service `workers` as its governing Service
3. Make sure both Pods are `Ready`.
4. Save the fully qualified DNS name of Pod `worker-1` that other Pods in the
   cluster can resolve to the file `~/cka/sn-13/worker-1-fqdn.txt`.
