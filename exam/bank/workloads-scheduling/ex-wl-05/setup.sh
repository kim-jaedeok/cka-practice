#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-05
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" batch-shards

kctx -n batch-shards create configmap shard-map \
  --from-literal=shard-0=eu-west \
  --from-literal=shard-1=eu-north \
  --from-literal=shard-2=us-east \
  --from-literal=shard-3=ap-south >/dev/null
