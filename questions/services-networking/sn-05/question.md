Connect with `ssh gateway-admin`, then solve this question on the designated
disposable Gateway cell.

Envoy Gateway is running with GatewayClass `envoy-cka`. In namespace `traffic`,
Deployment `store` is exposed by Service `store-svc` on port 80.

1. Create Gateway `main-gw` in namespace `traffic`:
   - GatewayClass `envoy-cka`
   - exactly one listener named `http`
   - protocol HTTP, port 80, hostname `shop.example.com`

2. Create HTTPRoute `store-route` in namespace `traffic`:
   - attach it to listener `http` of Gateway `main-gw`
   - exactly one hostname, `shop.example.com`
   - route PathPrefix `/store` to Service `store-svc`, port 80

3. Wait until the Gateway is `Accepted=True` and `Programmed=True`, and the
   HTTPRoute parent reports `Accepted=True` and `ResolvedRefs=True`.

The grader sends real HTTP requests through the Envoy data plane. A resource
specification without a functioning route does not receive full credit.
