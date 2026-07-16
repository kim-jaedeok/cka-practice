Solve this question on: `kubectl config use-context kind-cka`

In namespace `dns-test` a Service `web-dns` is running.

1. Create a Pod named `dns-checker` in namespace `dns-test`,
   image `busybox:1.36`, command `sleep infinity`.

2. From inside `dns-checker`, resolve the following names with `nslookup`
   and save the **full command output** to files on the host:
   - `web-dns.dns-test.svc.cluster.local` → `~/cka/sn-06/svc.txt`
   - `kubernetes.default.svc.cluster.local` → `~/cka/sn-06/kubernetes.txt`
