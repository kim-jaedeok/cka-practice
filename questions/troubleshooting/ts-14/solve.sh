#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

NODE=cka-worker

docker exec "$NODE" sh -c '
  test -f /etc/cni/net.d/10-calico.conflist.cka-disabled
  mv /etc/cni/net.d/10-calico.conflist.cka-disabled \
    /etc/cni/net.d/10-calico.conflist
  systemctl enable --now containerd
'

for _ in $(seq 1 90); do
  node_ready="$(kctx get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  pod_ready_state="$(kctx -n runtime-check get pod runtime-probe -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$node_ready" = True ] && [ "$pod_ready_state" = True ] && exit 0
  sleep 2
done
exit 1
