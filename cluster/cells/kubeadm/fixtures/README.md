# kubeadm cell fixtures

The bootstrap cell does not download a network add-on after the exercise
starts.  During trusted preparation it copies kind's generated
`/kind/manifests/default-cni.yaml` from the digest-pinned node image to
`/opt/cka/kindnet.yaml`, then resets the node.  The candidate applies that
local manifest after `kubeadm init`.

The HA fixture is deliberately created before `cp2` and `cp3` are reset.  Its
Deployment UID is captured as protected evidence, allowing the grader and the
active failover contract to distinguish continuity from delete-and-recreate.

Official procedure and invariants:

- kubeadm cluster creation:
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm join:
  https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
- kubeadm high availability:
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- kubeadm reset limitations:
  https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
