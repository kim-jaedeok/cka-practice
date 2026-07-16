Solve this question on: `kubectl config use-context kind-cka`

Applications across the cluster report DNS resolution failures
(e.g. `nslookup kubernetes.default` fails from Pods).

1. Investigate the cluster DNS components in namespace `kube-system`
   and find the root cause.
2. Fix the problem so that CoreDNS runs healthy again (2/2 Ready) and
   DNS resolution works from Pods.
