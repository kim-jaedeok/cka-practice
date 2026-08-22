# Disposable practice cells

`lib/cell.sh` provides one runner-facing lifecycle contract for the seven
individual-only exercises that must not mutate the persistent `kind-cka`
cluster:

```text
cell_prepare  <question-id> <environment>
cell_activate <question-id> <environment>
cell_cleanup  <question-id> <environment>
cell_status   <question-id> <environment>
```

| Environment | Questions | What it supplies |
|---|---|---|
| `kubeadm-upgrade` | `ca-06` | v1.35 control plane and a real v1.34 worker for an N-1→N package upgrade |
| `kubeadm-ha` | `ca-11` | load balancer, initialized `cp1`, blank `cp2`/`cp3`, three workers, stacked-etcd HA (High Availability) join and failover path |
| `kubeadm-bootstrap` | `ca-12` | blank `cp1`/`worker1`/`worker2` hosts for `kubeadm init` and `join` |
| `operator-cell` | `ca-09`, `ca-13` | cert-manager configure/reconcile and offline operator-install cells |
| `gateway-cell` | `sn-05` | Envoy Gateway and an HTTP (Hypertext Transfer Protocol) data-path exercise |
| `csi-cell` | `st-06` | a blank extension cell for the locked CSI (Container Storage Interface) driver |

The kubeadm topologies use `cluster/cells/kubeadm/`; controller and CSI cells
use the smaller `cluster/cells/generic/` kind topology. They never reuse the
persistent cluster name, context, containers, or network.

Each run gets a random cluster name and a dedicated Docker network. The
protected native-Linux manifest records full immutable container and network
identifiers. Cleanup verifies those identifiers, kind's exact cluster label, the cell-owner
label and network membership. It refuses name-based deletion, unrecorded
objects, symlinked state, foreign ownership, and non-native Windows Subsystem
for Linux (WSL) state filesystems.

The manifest defaults to
`${XDG_STATE_HOME:-$HOME/.local/state}/cka-practice/cells`, not the
session-scoped `XDG_RUNTIME_DIR`, so `start`, grading and cleanup may run in
separate WSL sessions. Creation writes a `PREPARING` intent before allocating
the Docker network, then atomically seals each verified container and its
anonymous-volume fingerprints. Cleanup first repairs an interrupted
`PREPARING` journal from the exact run-labelled network and deterministic kind
objects; any extra container, endpoint, attachment or fingerprint drift fails
closed before deletion.

If a legacy/session-state failure lost the manifest entirely, an administrator
may reconstruct only a caller-specified exact cell. This command performs no
Docker deletion; inspect the recovered manifest before running normal cleanup:

```bash
CKA_ENABLE_DISPOSABLE_CELLS=1 bash -lc '
  source lib/cell.sh
  cell_recover_preparing ca-12 kubeadm-bootstrap \
    cka-cell-ca-12-0123456789ab
'
```

Recovery requires the network's full owner label to match the 12-hex random
name suffix and question, every profile role to have its exact deterministic
name, kind cluster label and network membership, the network endpoint set to
contain no ID outside those immutable existing containers, and all
anonymous-volume generations to be fingerprinted. A stopped sealed container
may be absent from Docker's current endpoint map; an unsealed endpoint is
always rejected. Recovery never performs a global scan, prune or name-based
delete.

## Candidate access

After `cka start <id>`, the question becomes the selected active cell. The
`bin/ssh` wrapper revalidates its immutable manifest on every connection.

```bash
ssh cp1
ssh worker2 systemctl status kubelet
ssh operator-admin
ssh gateway-admin
ssh st06-admin
```

`cp*` and `worker*` aliases enter the verified node container. The named admin
aliases open a host shell with only that cell's kubeconfig and context. Starting
a shared-kind question or running `cka cleanup <id>` clears the selection, so a
stale alias does not silently fall back to another cell.

## Offline preparation

Question setup never downloads the version-sensitive package, manifest, or
image assets. Cache them once from a trusted online WSL/amd64 environment:

```bash
bash cluster/cells/kubeadm/cache-packages.sh
bash cluster/controllers/cache-assets.sh
bash cluster/csi/cache-images.sh
```

`ca-06` accepts only the exact `.deb` package names and SHA-256 (Secure Hash
Algorithm 256-bit) values in `cluster/cells/kubeadm/packages.lock`. Controller
and CSI caches have their own checksum and image-digest locks.

## Live verification

Cluster-free syntax, metadata, ownership, lifecycle and grader contracts pass.
The expensive paths are separate opt-in tests:

```bash
CKA_ENABLE_KUBEADM_CELLS=1 CKA_RUN_KUBEADM_LIVE_TESTS=1 \
  bash tests/kubeadm-live-test.sh
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-09
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-13
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only sn-05
CKA_CSI_LIVE=1 bash tests/csi-live-test.sh
```

On 2026-08-22 all seven disposable exercises passed their live gates. The
kubeadm results covered `ca-12` blank init/join, `ca-11` three-control-plane
stacked-etcd membership plus API (Application Programming Interface) write and
Service traffic while `cp1` remained stopped, and the real `ca-06` v1.34 to
v1.35 worker upgrade. `ca-09` reconciled a Certificate, `ca-13` installed the
offline operator and reconciled the existing Certificate, and `sn-05` proved
Gateway status and an HTTP data path. `st-06` gave both the canonical solution
and a semantically equivalent alternative 10/10. Exact cleanup succeeded after
every disposable run. The HA cell still runs all containers on one host, so it
does not model production failure domains.

Official references:

- [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
- [Creating a kubeadm cluster](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [kubeadm HA topology and join sequence](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [kubeadm join](https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Upgrading Linux nodes with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/)
- [kubeadm reset limitations](https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/)
- [Kubernetes Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
- [Gateway API HTTP routing](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/)
- [Deploying a CSI driver](https://kubernetes-csi.github.io/docs/deploying.html)
- [Docker container removal and anonymous volumes](https://docs.docker.com/reference/cli/docker/container/rm/)
- [Docker volume inspection](https://docs.docker.com/reference/cli/docker/volume/inspect/)
- [Docker volume removal](https://docs.docker.com/reference/cli/docker/volume/rm/)
