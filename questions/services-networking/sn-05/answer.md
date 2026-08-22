# sn-05 answer — live Gateway API routing

```bash
kubectl -n traffic apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gw
spec:
  gatewayClassName: envoy-cka
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: shop.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store-route
spec:
  parentRefs:
    - name: main-gw
      sectionName: http
  hostnames: [shop.example.com]
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      backendRefs:
        - name: store-svc
          port: 80
EOF

kubectl -n traffic get gateway main-gw
kubectl -n traffic get httproute store-route -o yaml
```

The lab's GatewayClass references an EnvoyProxy whose generated Service is
ClusterIP. This keeps the proof entirely inside the disposable cell while still
exercising the real Envoy controller and proxy data path. The setup preloads the
Envoy, nginx backend, and BusyBox probe images from exact verified archives;
their workload specs use digest-pinned references and `imagePullPolicy: Never`,
so this route proof does not depend on a registry being reachable.

Official references:

- https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/
- https://gateway.envoyproxy.io/docs/tasks/traffic/backend/
- https://gateway.envoyproxy.io/docs/api/extension_types/#envoyproxy
- https://kubernetes.io/docs/concepts/containers/images/
