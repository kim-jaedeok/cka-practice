#!/usr/bin/env bash
# Deliberately incomplete: Service and CNI are repaired; kube-proxy stays broken.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n service-chain patch service web-service --type=merge \
  -p '{"spec":{"selector":{"app":"web"}}}' >/dev/null
docker exec cka-worker2 sh -c '
  mv -f /etc/cni/net.d/10-calico.conflist.cka-disabled \
    /etc/cni/net.d/10-calico.conflist
'
