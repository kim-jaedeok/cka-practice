#!/usr/bin/env bash
# Near-miss fixture: the upgrade to 0.2.0 is correct, but the requested Helm
# rollback was skipped.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
command -v helm >/dev/null 2>&1 || PATH="$HOME/.local/bin:$PATH"
W="$CKA_WORK_DIR/ex-ca-06"

helm --kube-context "$CKA_CONTEXT" -n ops-dash upgrade board "$W/status-board-0.2.0" \
  -f "$W/prod-values.yaml" --set image.tag=1.29 >/dev/null
kctx -n ops-dash rollout status deploy/board --timeout=120s >/dev/null
