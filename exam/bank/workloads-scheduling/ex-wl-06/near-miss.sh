#!/usr/bin/env bash
# Near-miss fixture: the partition is set, but the new image was never rolled
# out, so no Pod runs the canary version.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n quorum patch sts kv --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}' >/dev/null
sleep 3
