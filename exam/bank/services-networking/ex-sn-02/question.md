Solve this question on: `cka-use-context ex-sn-02`

In namespace `docs-portal` three Services already exist, each on port `80`:
`docs-v1`, `docs-v2` and `status-page`. The cluster runs the ingress-nginx
controller with the IngressClass `nginx`.

Create one Ingress named `portal` in namespace `docs-portal` that uses the
IngressClass `nginx` and routes:

| Host | Path | Path type | Backend |
|---|---|---|---|
| `docs.portal.test` | `/status` | `Exact` | `status-page:80` |
| `docs.portal.test` | `/` | `Prefix` | `docs-v2:80` |
| `legacy.portal.test` | `/` | `Prefix` | `docs-v1:80` |

A request for `docs.portal.test/status/history` must reach `docs-v2`, not
`status-page`.

You can test from inside the cluster against the controller Service
`ingress-nginx-controller.ingress-nginx.svc.cluster.local` with a `Host` header.
