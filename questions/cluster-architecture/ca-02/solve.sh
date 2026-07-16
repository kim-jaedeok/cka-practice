#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx create clusterrole node-viewer --verb=get --verb=list --resource=nodes
kctx create clusterrolebinding node-viewer-binding \
  --clusterrole=node-viewer --serviceaccount=dev-team:node-inspector
