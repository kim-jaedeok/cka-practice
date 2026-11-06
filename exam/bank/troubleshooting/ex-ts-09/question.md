Solve this question on: `cka-use-context ex-ts-09`

The security team locked down outgoing traffic in namespace `checkout`. Since
then the Deployment `cart` (Pod label `app=cart`) cannot call the pricing
service at `http://pricing.catalog.svc.cluster.local/`.

Two NetworkPolicies exist in `checkout`: `default-deny-egress` and
`cart-egress`. `cart-egress` was meant to allow exactly two kinds of outgoing
traffic from `cart`: DNS lookups through the cluster DNS, and HTTP to the
`pricing` Pods in namespace `catalog`.

1. Find out why `cart` cannot reach `pricing`.
2. Fix the problem by changing the NetworkPolicy `cart-egress` only, so that
   `cart` can resolve and call `http://pricing.catalog.svc.cluster.local/`.
3. `cart` must still be unable to reach any other Pod or Service, for example
   `inventory.catalog`.
4. Do not modify or delete `default-deny-egress`, do not create other
   NetworkPolicies, and do not change any labels, Pods, Deployments or
   Services.
