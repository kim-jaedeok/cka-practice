# Solution

On `cp1`:

```bash
kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
ssh worker2
```

On `worker2`:

```bash
export DEBIAN_FRONTEND=noninteractive
KUBELET_DEFAULTS_SHA256="$(sha256sum /etc/default/kubelet | awk '{print $1}')"

apt-mark unhold kubeadm
apt-get -o Dpkg::Options::=--force-confold install -y \
  /opt/cka/packages/kubeadm_1.35.0-1.1_amd64.deb
apt-mark hold kubeadm
kubeadm upgrade node

apt-mark unhold kubelet kubectl
apt-get -o Dpkg::Options::=--force-confold install -y \
  /opt/cka/packages/kubelet_1.35.0-1.1_amd64.deb \
  /opt/cka/packages/kubectl_1.35.0-1.1_amd64.deb
test "$(sha256sum /etc/default/kubelet | awk '{print $1}')" = \
  "$KUBELET_DEFAULTS_SHA256"
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
exit
```

Back on `cp1`:

```bash
kubectl wait --for=condition=Ready node/worker2 --timeout=180s
kubectl uncordon worker2
kubectl get nodes
kubectl -n node-upgrade rollout status deployment/payments-api
```

This cell downgrades and upgrades the official `kubeadm`, `kubelet`, and
`kubectl` Debian packages. The kubelet version reported by the Node therefore
changes from `v1.34.0` to `v1.35.0`.

Official procedure:
https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
