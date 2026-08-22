Solve this question on: `kubectl config use-context kind-cka`

Namespace `lb-shop` contains a ready Deployment named `store` with two Pods.
Each Pod has label `app=store`, listens on port `80`, and returns the text
`cka-sn09-loadbalancer`.

Create a Service named `store-lb` in namespace `lb-shop` with all of the
following properties:

- type `LoadBalancer`
- selector `app=store`
- exactly one `TCP (Transmission Control Protocol)` port: Service port `80`
  to target port `80`

The Service must receive an external address and an HTTP (Hypertext Transfer
Protocol) request to that address on port `80` must return
`cka-sn09-loadbalancer`. Do not edit the `store` Deployment.
