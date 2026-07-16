Solve this question on: `kubectl config use-context kind-cka`

The platform team wants DNS query logging enabled for debugging.

1. Modify the CoreDNS configuration so that CoreDNS **logs all queries**
   (enable the `log` plugin in the default server block of the Corefile).

2. Roll out the change and make sure both CoreDNS Pods are running again
   and cluster DNS resolution still works.

3. Save the ClusterIP of the cluster DNS Service (`kube-dns` in
   `kube-system`) to the file `~/cka/sn-08/dns-ip.txt`.
