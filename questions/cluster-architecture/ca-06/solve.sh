#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"

export CKA_CELL_DOCKER_TIMEOUT="${CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-420}"
source "$CKA_ROOT/cluster/cells/kubeadm/package-cache.sh"

cell_activate ca-06 kubeadm-upgrade
NODE="$CKA_CELL_NODE_WORKER2"
TARGET="$KUBEADM_PACKAGE_TO_VERSION"

kctx drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s

cell_exec ca-06 worker2 bash -c '
  set -euo pipefail
  version="$1"
  kubelet_defaults=/etc/default/kubelet
  [ -f "$kubelet_defaults" ] && [ ! -L "$kubelet_defaults" ]
  kubelet_defaults_sha256="$(sha256sum "$kubelet_defaults" | awk '\''{print $1}'\'')"
  [[ "$kubelet_defaults_sha256" =~ ^[0-9a-f]{64}$ ]]
  export DEBIAN_FRONTEND=noninteractive
  apt-mark unhold kubeadm
  apt-get -o Dpkg::Options::=--force-confold install -y \
    "/opt/cka/packages/kubeadm_${version}_amd64.deb"
  apt-mark hold kubeadm
  kubeadm upgrade node
  apt-mark unhold kubelet kubectl
  apt-get -o Dpkg::Options::=--force-confold install -y \
    "/opt/cka/packages/kubelet_${version}_amd64.deb" \
    "/opt/cka/packages/kubectl_${version}_amd64.deb"
  [ "$(sha256sum "$kubelet_defaults" | awk '\''{print $1}'\'')" = \
      "$kubelet_defaults_sha256" ]
  apt-mark hold kubelet kubectl
  systemctl daemon-reload
  systemctl restart kubelet
' _ "$TARGET"

kctx wait --for=condition=Ready "node/$NODE" --timeout=180s >/dev/null
kctx uncordon "$NODE"
wait_deploy node-upgrade payments-api 180s
