# Container Storage Interface (CSI) disposable lab assets

`st-06` installs the upstream Kubernetes CSI
host-path sample driver in its own `csi-cell`. The candidate must apply the
locked offline driver manifest, create a StorageClass, dynamically provision a
PersistentVolumeClaim (PVC), attach it to a Pod, and write the expected data.
The grader verifies:

- the driver StatefulSet and required sidecars;
- CSIDriver and CSINode registration;
- the StorageClass contract;
- PVC→dynamically provisioned CSI PersistentVolume (PV) relationships;
- Pod placement, volume attachment, mount and `/data/proof.txt` contents.

A static PV, `hostPath`, or `local` volume does not satisfy the task.

## Trusted preparation and use

The checked-in candidate manifest is checksum-locked. Container images are
pulled only by the trusted online preparation command for `linux/amd64`:

```bash
bash cluster/csi/cache-images.sh
cka start st-06
ssh st06-admin
# solve the task
cka grade st-06
cka cleanup st-06
```

The cache command pulls exact platform-manifest digests and creates a local
Docker archive. Before publishing or loading it, the runtime verifies the full
OCI (Open Container Initiative) content closure against the locked image tag,
platform-manifest digest, config digest and `linux/amd64` platform. The adjacent
SHA-256 (Secure Hash Algorithm 256-bit) checksum remains a truncation check; it
is not treated as the provenance trust root.

After `kind load image-archive`, every node is checked through CRI (Container
Runtime Interface). The loader explicitly registers each locked
`repository@digest` name in the cell's `k8s.io` containerd namespace and waits
for CRI's asynchronous image cache to observe it. The candidate manifest uses
`imagePullPolicy: Never`, so a missing or mismatched local identity fails before
Kubernetes can fall back to a registry pull.

Every CSI setup, teardown and preload mutation now requires the active-cell
selection to match the native-Linux immutable manifest's question, profile,
run ID, exact kubeconfig/context and verified Docker topology. A lookalike
`kind-cka-cell-st-06-*` context alone is therefore rejected. Cell creation uses
kind's explicit bounded `--wait`, then polls the API `/readyz` endpoint before
publishing `READY`. The outer question setup, kind creation, archive import and
per-node Docker checks each have process deadlines; a timed-out `PREPARING`
start still enters exact immutable-ID cleanup and clears its selection.

## Verification status

The cluster-free asset, metadata, isolation and semantic-grader contracts pass.
The current local cache also passes Docker-free archive closure verification.
The full storage data path is an explicit live test:

```bash
CKA_CSI_LIVE=1 bash tests/csi-live-test.sh
```

The 2026-08-22 live gate passed the repaired CRI digest-name mapping, the valid
`reg-health` port, all five plugin containers, dynamic provisioning, attachment
and the writer data path. Both the canonical solution and a semantically valid
alternative without the reference answer's optional `nodeSelector` received
10/10, and exact disposable-cell cleanup succeeded. CSINode registration is per
node, so additional registered nodes are valid, and the CSIDriver API defaults
an empty lifecycle list to `Persistent`. The semantic criterion requires attach
behavior, support for `Persistent`, and at least one host-path registration; the
writer criterion separately proves that the consuming node is registered and
attached.

The runner exposes and bounds canonical grade, delete request, deletion wait,
alternative apply, Ready wait, alternative grade and cleanup as separate
stages. On failure it prints the score state, API-defaulted CSIDriver spec,
node-by-node CSINode driver summary, Pod deletion/finalizer fields,
PersistentVolumes, VolumeAttachments and writer events before preserving the
cleanup output. The grader's API reads have per-request deadlines and its
streaming data-path `exec` has a process deadline. A changed asset lock,
manifest, loader, grader or runtime requires a fresh live rerun.

Official sources:

- [Kubernetes CSI host-path sample driver v1.18.0](https://github.com/kubernetes-csi/csi-driver-host-path/tree/v1.18.0)
- [Deploying a CSI driver](https://kubernetes-csi.github.io/docs/deploying.html)
- [CSI external-provisioner v6.3.0](https://github.com/kubernetes-csi/external-provisioner/tree/v6.3.0/deploy/kubernetes)
- [CSI external-attacher v4.12.0](https://github.com/kubernetes-csi/external-attacher/tree/v4.12.0/deploy/kubernetes)
- [kind: loading an image archive into a cluster](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster)
- [kind: creating a cluster and bounded `--wait`](https://kind.sigs.k8s.io/docs/user/quick-start/#creating-a-cluster)
- [containerd `ctr images import` digest-reference option](https://github.com/containerd/containerd/blob/main/cmd/ctr/commands/images/import.go)
- [containerd CRI local image-reference resolution](https://github.com/containerd/containerd/blob/main/internal/cri/server/images/service.go)
- [Kubernetes image pull policies](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy)
- [Kubernetes `IANA_SVC_NAME` port-name validation](https://github.com/kubernetes/apimachinery/blob/master/pkg/util/validation/validation.go)
- [Kubernetes `kubectl wait`, including a separate deletion wait](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_wait/)
- [Kubernetes `kubectl` request timeout](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_options/)
- [Kubernetes API health endpoints (`livez` and `readyz`)](https://kubernetes.io/docs/reference/using-api/health-checks/)
- [Kubernetes kubeconfig contexts](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [GNU Coreutils `timeout`](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html)
- [Kubernetes CSIDriver API](https://kubernetes.io/docs/reference/kubernetes-api/storage/csi-driver-v1/)
- [Kubernetes CSINode API and node-driver registration](https://kubernetes.io/docs/reference/kubernetes-api/storage/csi-node-v1/)
