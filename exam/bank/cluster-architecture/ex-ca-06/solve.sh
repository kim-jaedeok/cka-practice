#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
command -v helm >/dev/null 2>&1 || PATH="$HOME/.local/bin:$PATH"
W="$CKA_WORK_DIR/ex-ca-06"

helm --kube-context "$CKA_CONTEXT" -n ops-dash rollback board 1 >/dev/null
helm --kube-context "$CKA_CONTEXT" -n ops-dash upgrade board "$W/status-board-0.2.0" \
  -f "$W/prod-values.yaml" --set image.tag=1.29 >/dev/null
kctx -n ops-dash rollout status deploy/board --timeout=120s >/dev/null
