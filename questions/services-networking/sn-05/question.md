Solve this question on: `kubectl config use-context kind-cka`

The cluster has the Gateway API CRDs installed and a GatewayClass named `nginx`.
In namespace `traffic` a Deployment `store` is exposed by Service `store-svc`
on port `80`.

1. Create a Gateway:
   - Name: `main-gw`, namespace `traffic`
   - GatewayClass: `nginx`
   - One listener: name `http`, protocol `HTTP`, port `80`,
     hostname `shop.example.com`

2. Create an HTTPRoute:
   - Name: `store-route`, namespace `traffic`
   - Attach it to the Gateway `main-gw`
   - Hostname: `shop.example.com`
   - Route requests with path prefix `/store` to Service `store-svc` port `80`

(No Gateway controller is running in this lab — only the resource
specifications are evaluated.)
