#!/usr/bin/env bash
# Near-miss fixture: only the anti-affinity rule is added. Nothing ties the
# cache Pods to nodes that run web Pods.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n cache-tier patch deploy cache --type=strategic -p '
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: cache}
              topologyKey: kubernetes.io/hostname
' >/dev/null
wait_deploy cache-tier cache 240s
sleep 3
