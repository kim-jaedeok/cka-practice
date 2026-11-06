#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
NODE="${CKA_CLUSTER_NAME}-worker2"

# A mirror Pod cannot be edited through the API. Fix the manifest on the node;
# the kubelet then replaces the Pod.
docker exec "$NODE" sed -i 's#path: /livez#path: /healthz#' \
  /etc/kubernetes/manifests/edge-cache.yaml

# Wait until the new Pod has been Ready without restarts for more than 20s.
for _ in $(seq 1 60); do
  state="$(kctx -n edge-system get pod "edge-cache-$NODE" -o jsonpath='{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.running.startedAt}|{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  IFS='|' read -r restarts started ready <<< "$state"
  if [ "$restarts" = 0 ] && [ "$ready" = True ] && [ -n "$started" ]; then
    age=$(( $(date -u +%s) - $(date -u -d "$started" +%s) ))
    [ "$age" -ge 25 ] && exit 0
  fi
  sleep 3
done
exit 1
