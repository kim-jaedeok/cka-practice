Solve this question on: `cka-use-context ex-sn-03`

In namespace `telemetry` the Deployment `collector` (Pod label `app=collector`)
accepts data on TCP port `8080` and serves an admin interface on TCP port
`9090`. The Service `collector` exposes both ports. Right now every Pod in the
cluster can reach both ports.

The following Pods already exist:

| Namespace | Pod | Pod labels | Namespace labels |
|---|---|---|---|
| `edge-ingest` | `shipper` | `app=shipper` | `team=edge` |
| `edge-other` | `shipper` | `app=shipper` | `team=batch` |
| `telemetry` | `admin-shell` | `role=admin` | — |
| `telemetry` | `app-shell` | `role=app` | — |

Create a NetworkPolicy named `collector-access` in namespace `telemetry` that
selects the `collector` Pods so that:

1. Port `8080` accepts traffic only from Pods in namespaces labeled `team=edge`.
2. Port `9090` accepts traffic only from Pods labeled `role=admin` in namespace
   `telemetry`.
3. All other ingress traffic to the `collector` Pods is denied.

Do not change any labels, Pods, Deployments or Services.
