#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

# Set the partition first. Changing the image first would start replacing the
# Pods from the highest ordinal down before the partition protects them.
kctx -n quorum patch sts kv --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}' >/dev/null
kctx -n quorum set image sts/kv kv=nginx:1.29 >/dev/null
kctx -n quorum rollout status sts/kv --timeout=180s >/dev/null
