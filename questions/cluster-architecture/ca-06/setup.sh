#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"
source "$CKA_ROOT/cluster/cells/kubeadm/package-cache.sh"

QID=ca-06
cell_prepare "$QID" kubeadm-upgrade >/dev/null
cell_activate "$QID" kubeadm-upgrade
NODE="$CKA_CELL_NODE_WORKER2"

kctx uncordon "$NODE" >/dev/null 2>&1 || true
kctx delete namespace node-upgrade --ignore-not-found --wait=true \
  --timeout=90s >/dev/null 2>&1 || true
kctx create namespace node-upgrade >/dev/null
kctx label namespace node-upgrade "$CKA_LABEL_KEY=$QID" --overwrite >/dev/null

kctx apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: node-upgrade
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      nodeSelector:
        kubernetes.io/hostname: $NODE
      containers:
        - name: nginx
          image: nginx:1.29
EOF
wait_deploy node-upgrade payments-api 180s
kctx -n node-upgrade label pods -l app=payments-api \
  drain-probe=original --overwrite >/dev/null

cell_exec "$QID" worker2 bash -c \
  'find /etc/kubernetes/tmp -maxdepth 1 -type d -name "kubeadm-kubelet-config-*" -exec rm -rf -- {} + 2>/dev/null || true'

node_uid="$(kctx get node "$NODE" -o jsonpath='{.metadata.uid}')"
deployment_uid="$(kctx -n node-upgrade get deployment payments-api \
  -o jsonpath='{.metadata.uid}')"
kubelet_defaults_sha256="$(cell_exec "$QID" worker2 \
  sha256sum /etc/default/kubelet | awk '{print $1}')"
[[ "$kubelet_defaults_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || die "worker2 kubelet defaults checksum is unavailable"
evidence="$(cell_evidence_path "$QID")"
tmp="$(mktemp "$(dirname "$evidence")/.evidence.XXXXXX")"
chmod 0600 "$tmp"
{
  printf 'worker2_node_uid=%s\n' "$node_uid"
  printf 'payments_deployment_uid=%s\n' "$deployment_uid"
  printf 'kubelet_defaults_sha256=%s\n' "$kubelet_defaults_sha256"
  printf 'from_version=%s\n' "$KUBEADM_PACKAGE_FROM_VERSION"
  printf 'to_version=%s\n' "$KUBEADM_PACKAGE_TO_VERSION"
} > "$tmp"
mv -f -- "$tmp" "$evidence"

[ "$(kctx get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')" \
    = "v${KUBEADM_PACKAGE_FROM_VERSION%%-*}" ] \
  || die "worker2 did not start at the real N-1 kubelet version"
