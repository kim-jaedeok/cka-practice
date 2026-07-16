Solve this question on: `kubectl config use-context kind-cka`

In namespace `web-zone` two applications are already running and exposed:

- Service `web-a` (port 80) — serves content under path `/a`
- Service `web-b` (port 80) — serves content under path `/b`

Create an Ingress resource:

- Name: `web-ingress`, namespace `web-zone`
- IngressClass: `nginx`
- Host: `app.example.com`
- Route path `/a` (pathType `Prefix`) to Service `web-a` port `80`
- Route path `/b` (pathType `Prefix`) to Service `web-b` port `80`

Note: in this practice environment the ingress controller is reachable from the
host at `http://localhost:8080` (send the `Host: app.example.com` header to test).
