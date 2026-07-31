Solve this question on: `kubectl config use-context kind-cka`

Create a **static Pod** on node `cka-worker`:

- Name: `static-web`
- Image: `nginx:1.29`
- Container port: `80`

The kubelet on `cka-worker` reads static Pod manifests from
`/etc/kubernetes/manifests/`.

Afterwards verify with kubectl that the mirror Pod
`static-web-cka-worker` is Running.

Lab hint: access the node with `ssh cka-worker`.
