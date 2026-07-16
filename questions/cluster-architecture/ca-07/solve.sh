#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

helm install webapp-rel "$CKA_WORK_DIR/ca-07/chart/webapp" \
  -n helm-apps --set replicaCount=2 --kube-context "$CKA_CONTEXT"

helm upgrade webapp-rel "$CKA_WORK_DIR/ca-07/chart/webapp" \
  -n helm-apps --set replicaCount=2 --set image.tag=1.29 --kube-context "$CKA_CONTEXT"

wait_deploy helm-apps webapp-rel 180s
