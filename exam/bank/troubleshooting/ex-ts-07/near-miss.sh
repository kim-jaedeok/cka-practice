#!/usr/bin/env bash
# Near-miss fixture: the container runs, but only because the memory limit was
# removed. The task requires a limit of at most 256Mi.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n media-proc patch deploy thumbnailer --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits"}]' >/dev/null
kctx -n media-proc rollout status deploy/thumbnailer --timeout=120s >/dev/null
sleep 18
