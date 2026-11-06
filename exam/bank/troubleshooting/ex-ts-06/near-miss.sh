#!/usr/bin/env bash
# Near-miss fixture: the restarts stop because the liveness probe was removed
# from the static Pod manifest instead of being corrected.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
NODE="${CKA_CLUSTER_NAME}-worker2"

docker exec "$NODE" sed -i '/livenessProbe:/,$d' /etc/kubernetes/manifests/edge-cache.yaml

for _ in $(seq 1 60); do
  state="$(kctx -n edge-system get pod "edge-cache-$NODE" -o jsonpath='{.spec.containers[0].livenessProbe}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.running.startedAt}|{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  IFS='|' read -r probe restarts started ready <<< "$state"
  if [ -z "$probe" ] && [ "$restarts" = 0 ] && [ "$ready" = True ] && [ -n "$started" ]; then
    age=$(( $(date -u +%s) - $(date -u -d "$started" +%s) ))
    [ "$age" -ge 25 ] && exit 0
  fi
  sleep 3
done
exit 1
