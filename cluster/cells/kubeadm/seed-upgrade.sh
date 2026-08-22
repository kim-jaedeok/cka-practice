#!/usr/bin/env bash
# Seed hook for a future ca-06 disposable N-1 -> N upgrade cell.
#
# This helper intentionally refuses network downloads.  The caller supplies a
# protected package cache containing exact Kubernetes and dependency .deb files
# plus SHA256SUMS. That keeps the exercise real while making package provenance
# an integration-time decision in the dedicated package lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../lib/cell.sh"
source "$SCRIPT_DIR/package-cache.sh"

qid="${1:-ca-06}"
cache="${CKA_CELL_PACKAGE_CACHE:-}"
from_version="${CKA_CELL_UPGRADE_FROM_PACKAGE:-}"
to_version="${CKA_CELL_UPGRADE_TO_PACKAGE:-}"

[ "$qid" = ca-06 ]
[ -n "$cache" ] && [[ "$cache" = /* ]] && [ -d "$cache" ] && [ ! -L "$cache" ]
[[ "$from_version" =~ ^1\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]]
[[ "$to_version" =~ ^1\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]]
[ "$from_version" != "$to_version" ]
[ "$from_version" = "$KUBEADM_PACKAGE_FROM_VERSION" ]
[ "$to_version" = "$KUBEADM_PACKAGE_TO_VERSION" ]
[ -f "$cache/SHA256SUMS" ] && [ ! -L "$cache/SHA256SUMS" ]

cell_manifest_load "$qid"
[ "$CELL_PROFILE" = kubeadm-upgrade ] && [ "$CELL_STATUS" = PREPARING ]
cell_verify_container_id "$qid" worker2
worker_id="${CELL_CONTAINER_IDS[worker2]}"
cell_exec "$qid" worker2 install -d -m 0755 /opt/cka/packages

declare -a from_files=()
for package in cri-tools kubernetes-cni kubeadm kubelet kubectl; do
  from_package_version="$(kubeadm_package_version "$package" FROM)"
  to_package_version="$(kubeadm_package_version "$package" TO)"
  from="$cache/${package}_${from_package_version}_amd64.deb"
  to="$cache/${package}_${to_package_version}_amd64.deb"
  for file in "$from" "$to"; do
    [ -f "$file" ] && [ ! -L "$file" ]
    base="$(basename "$file")"
    expected="$(awk -v name="$base" '$2 == name {count++; sha=$1} END {if(count != 1) exit 1; print sha}' \
      "$cache/SHA256SUMS")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$expected" ]
    _cell_docker cp "$file" "$worker_id:/opt/cka/packages/$base"
  done
  from_files+=("/opt/cka/packages/${package}_${from_package_version}_amd64.deb")
done

cell_exec_stdin "$qid" worker2 bash -s -- "${from_files[@]}" <<'NODE'
set -euo pipefail
kubelet_defaults=/etc/default/kubelet
kubelet_defaults_sha256=
if [ -e "$kubelet_defaults" ] || [ -L "$kubelet_defaults" ]; then
  [ -f "$kubelet_defaults" ] && [ ! -L "$kubelet_defaults" ]
  kubelet_defaults_sha256="$(sha256sum "$kubelet_defaults" | awk '{print $1}')"
  [[ "$kubelet_defaults_sha256" =~ ^[0-9a-f]{64}$ ]]
fi

export DEBIAN_FRONTEND=noninteractive
apt-mark unhold cri-tools kubernetes-cni kubeadm kubelet kubectl >/dev/null 2>&1 || true
dpkg --force-confold --install "$@"
if [ -n "$kubelet_defaults_sha256" ]; then
  [ -f "$kubelet_defaults" ] && [ ! -L "$kubelet_defaults" ]
  [ "$(sha256sum "$kubelet_defaults" | awk '{print $1}')" = \
      "$kubelet_defaults_sha256" ]
fi
apt-mark hold cri-tools kubernetes-cni kubeadm kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
NODE

for package in cri-tools kubernetes-cni kubeadm kubelet kubectl; do
  expected_version="$(kubeadm_package_version "$package" FROM)"
  [ "$(cell_exec "$qid" worker2 dpkg-query -W -f='${Version}' "$package")" = \
      "$expected_version" ] \
    || die "$package did not install at locked N-1 version"
done

# Candidate-visible exact target packages remain local; no repository or
# network is required during the exercise.
cell_exec "$qid" worker2 bash -c \
  'printf "%s\n" "$1" > /opt/cka/packages/TARGET_VERSION' _ "$to_version"

worker2="$(cell_role_node_name "$CELL_CLUSTER_NAME" worker2)"
cell_kubectl "$qid" wait --for=condition=Ready "node/$worker2" --timeout=180s >/dev/null
[ "$(cell_kubectl "$qid" get node "$worker2" \
    -o jsonpath='{.status.nodeInfo.kubeletVersion}')" = "v${from_version%%-*}" ] \
  || die "worker2 did not report the real N-1 kubelet version"
