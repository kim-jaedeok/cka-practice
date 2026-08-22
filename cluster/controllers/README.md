# Offline controller assets

The controller labs use real upstream controllers in disposable cells:

- `ca-09`: cert-manager is installed before hand-off. The candidate creates an
  Issuer and Certificate; grading requires the current generation to be
  reconciled and validates the controller-owned TLS (Transport Layer Security)
  Secret.
- `ca-13`: only cert-manager CRDs (Custom Resource Definitions) are installed
  before hand-off. The candidate installs the exact offline manifest and must
  make an existing Certificate reconcile.
- `sn-05`: Envoy Gateway is installed before hand-off. The candidate creates a
  Gateway and HTTPRoute; grading checks status and sends
  HTTP (Hypertext Transfer Protocol) requests through
  the Envoy data plane.

The labs reject the shared `kind-cka` context. Their cluster-scoped CRDs,
webhooks, GatewayClass and generated resources live only in the question's
`operator-cell` or `gateway-cell` and are removed by `cka cleanup <id>`.

## Trusted preparation

No manifest or image is fetched while a question is prepared, solved, or
graded. Run both cache steps in this order on an online trusted `linux/amd64`
host:

```bash
bash cluster/cells/kubeadm/cache-packages.sh
bash cluster/controllers/cache-assets.sh
```

The first command creates the exact nginx/BusyBox workload bundle reused by
`sn-05`; the controller cache command verifies that bundle before making any
network request. It then downloads the pinned official release manifests,
verifies the committed SHA-256 (Secure Hash Algorithm 256-bit) values, and
fetches each immutable platform manifest and referenced blob through the
Distribution Registry HTTP API. It verifies every digest and size while
building a platform-scoped OCI (Open Container Initiative) archive under
`assets/`; the independent runtime verifier checks the completed content
closure again before loading anything into a cell. Adding another architecture
requires committing every platform-manifest and image-config digest first.

This direct, content-addressed path deliberately does not use `docker pull` →
`docker tag` → `docker save`. Docker Engine 29 enables the containerd image
store by default on fresh installations, and the upstream Moby project tracks
a regression in which a freshly pulled platform image can be inspectable but
`docker save --platform` rejects it or omits referenced blobs. The cache must
fail closed on that condition rather than publish a truncated archive.

At cell-preparation time, KIND (Kubernetes IN Docker) imports the already
verified archive into every disposable node. containerd can synthesize an
`import-<date>@sha256:...` reference for content imported with `ctr`, so that
reference is not evidence that the original repository digest used by a Pod is
available through CRI (Container Runtime Interface). The runtime therefore
checks the imported tag's exact containerd manifest target and that manifest's
locked config digest before locally publishing the same target as the locked
`repository@sha256:...` reference. It then waits for the bounded CRI visibility
check. No registry access or image-content rewrite occurs in this step.

Runner-facing entry points are:

```text
controller_cell_prepare  <qid> <environment>
controller_cell_activate <qid> <environment>
controller_cell_status   <qid> <environment>
controller_cell_cleanup  <qid> <environment>
```

## Verification status

The cluster-free asset, isolation, lifecycle and semantic-grader contracts
pass. Live reconciliation and network-path checks are opt-in:

```bash
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-09
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-13
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only sn-05
```

The implementation workspace cache was regenerated through this path and both
archives passed exact closure verification and a Docker Engine 29 load/identity
check. On 2026-08-22 all three live gates also passed: `ca-09` observed
cert-manager reconciliation and its controller-owned Secret, `ca-13` installed
the exact offline operator and reconciled the existing Certificate, and
`sn-05` observed accepted Gateway/HTTPRoute status and a successful HTTP data
path through Envoy. Exact disposable-cell cleanup passed after every run. The
commands above remain the required way to revalidate a changed lock, cache,
controller manifest, grader, or runtime.

Pinned official sources:

- [cert-manager installation](https://cert-manager.io/docs/installation/)
- [cert-manager Certificate usage](https://cert-manager.io/docs/usage/certificate/)
- [Gateway API v1.6.1 Standard Channel bundle](https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/)
- [Gateway API HTTP routing](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/)
- [Envoy Gateway v1.9.0 release](https://github.com/envoyproxy/gateway/releases/tag/v1.9.0)
- [Envoy Gateway compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/)
- [Distribution Registry HTTP API V2](https://distribution.github.io/distribution/spec/api/)
- [OCI image-layout specification](https://github.com/opencontainers/image-spec/blob/main/image-layout.md)
- [Docker Engine containerd image store](https://docs.docker.com/engine/storage/containerd/)
- [Docker image save platform behavior](https://docs.docker.com/reference/cli/docker/image/save/)
- [Moby containerd-store save regression #52193](https://github.com/moby/moby/issues/52193)
- [KIND loading an image archive](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster)
- [containerd direct image loading for CRI](https://github.com/containerd/containerd/blob/main/docs/cri/crictl.md#directly-load-a-container-image)
- [containerd imported digest-reference behavior in KIND #7698](https://github.com/containerd/containerd/issues/7698)
