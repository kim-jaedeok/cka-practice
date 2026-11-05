Solve this question on: `cka-use-context ex-sn-01`

The Pod `legacy-app` in namespace `legacy-host` stands in for a legacy server
outside Kubernetes. Treat its Pod IP as a fixed address. It serves HTTP on
port `80`.

Applications in namespace `bridge` must reach it through a Service name.

1. In namespace `bridge`, create a Service `legacy-api` of type `ClusterIP`
   **without a selector**. It has one port: name `http`, port `8080`,
   protocol `TCP`.
2. In namespace `bridge`, create an EndpointSlice `legacy-api-1` that connects
   the Service `legacy-api` to the IP address of `legacy-app` on port `80`.
3. Requests to `http://legacy-api.bridge.svc.cluster.local:8080/` must be
   answered by `legacy-app`.

Do not modify `legacy-app`, and do not create Pods or Deployments.
