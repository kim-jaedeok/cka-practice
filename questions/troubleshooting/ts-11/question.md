Solve this question on: `kubectl config use-context kind-cka`

In namespace `shop` the application `checkout` works fine when accessed via
its Service directly, but requests through the Ingress
(`http://localhost:8080/` with header `Host: shop.example.com`) fail.

An Ingress `shop-ingress` already exists in namespace `shop`.

1. Find the problems in the Ingress resource (there are TWO mistakes).
2. Fix the Ingress so that
   `curl -H "Host: shop.example.com" http://localhost:8080/` returns the
   application response.
3. Do NOT modify the Deployment or the Service.
