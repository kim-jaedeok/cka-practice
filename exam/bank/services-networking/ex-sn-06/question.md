Solve this question on: `cka-use-context ex-sn-06`

The applications in namespace `shop-frontend` call the payment backend at
`http://payments:8080/`. Today the Service `payments` in `shop-frontend` sends
this traffic to the old Deployment `payments-legacy` in the same namespace.

The payment team now runs the new backend as the Service `payments-api`
(port `8080`) in namespace `payments-core`.

1. Change the Service `payments` in namespace `shop-frontend` into a Service of
   type `ExternalName` that points to the Service `payments-api` in namespace
   `payments-core` by its fully qualified cluster DNS name. The applications
   must keep using the name `payments`.
2. Delete the Deployment `payments-legacy`.
3. A request from the Deployment `web-client` to `http://payments:8080/` must
   be answered by `payments-api`.

Do not change anything in namespace `payments-core`. Do not create Pods,
Deployments or EndpointSlices.
