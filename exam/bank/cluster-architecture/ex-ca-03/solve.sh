#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

overlay="$CKA_WORK_DIR/ex-ca-03/overlays/staging"
sed -i 's#- ../base$#- ../../base#' "$overlay/kustomization.yaml"
sed -i 's#name: ngnix$#name: nginx#' "$overlay/kustomization.yaml"
kctx apply -k "$overlay" >/dev/null
wait_deploy kz-staging stg-catalog 180s
