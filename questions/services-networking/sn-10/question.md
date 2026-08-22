Solve this question on: `kubectl config use-context kind-cka`

The following namespaces and workloads already exist:

- `sn10-checkout`: Pod and Service `checkout`, both using `app=checkout`
- `sn10-monitoring`: Pod `probe` with `access=monitor`, and Pod `other`
  with `access=other`; the namespace has label
  `cka-practice/sn-10-role=monitoring`
- `sn10-untrusted`: Pod `probe` with `access=monitor`; the namespace has label
  `cka-practice/sn-10-role=untrusted`
- `sn10-catalog`: Service `catalog-svc` selects `app=catalog`, while Service
  `admin-svc` selects `app=admin`; the namespace has label
  `cka-practice/sn-10-role=catalog`

All HTTP (Hypertext Transfer Protocol) servers listen on port `8080`.

Create four NetworkPolicies in namespace `sn10-checkout`:

1. `isolate-checkout`: select `app=checkout` and deny all ingress and egress by
   default.
2. `allow-monitoring-ingress`: allow ingress to `app=checkout` only from Pods
   that are both in namespaces labeled
   `cka-practice/sn-10-role=monitoring` and labeled `access=monitor`, only on
   `TCP (Transmission Control Protocol)` port `8080`.
3. `allow-dns-egress`: allow `app=checkout` egress to CoreDNS Pods labeled
   `k8s-app=kube-dns` in namespace `kube-system`, on both UDP (User Datagram
   Protocol) port `53` and TCP port `53`.
4. `allow-catalog-egress`: allow `app=checkout` egress only to Pods labeled
   `app=catalog` in namespaces labeled `cka-practice/sn-10-role=catalog`, only
   on TCP port `8080`.

Expected result:

- `sn10-monitoring/probe` can reach `checkout`; the other two probes cannot.
- `sn10-checkout/checkout` can resolve DNS (Domain Name System) names and reach
  `catalog-svc`, but cannot reach `admin-svc`.

Do not edit the existing Pods, Services, or namespace labels.
