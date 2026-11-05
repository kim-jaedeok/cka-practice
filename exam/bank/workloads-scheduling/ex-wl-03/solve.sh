#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n cache-tier patch deploy cache --type=strategic -p '
spec:
  template:
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: web}
              topologyKey: kubernetes.io/hostname
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: cache}
              topologyKey: kubernetes.io/hostname
' >/dev/null
wait_deploy cache-tier cache 240s
kctx -n cache-tier wait --for=delete pod -l app=cache --field-selector=status.phase!=Running \
  --timeout=60s >/dev/null 2>&1 || true
sleep 3
