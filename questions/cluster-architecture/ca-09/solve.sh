#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ca-09"
kctx get crd -o name | sed 's|^customresourcedefinition.*/||' > "$CKA_WORK_DIR/ca-09/crds.txt"
kctx explain backup.spec > "$CKA_WORK_DIR/ca-09/spec.txt"

kctx apply -f - <<'EOF'
apiVersion: stable.example.com/v1
kind: Backup
metadata:
  name: db-backup
  namespace: operators
spec:
  source: /data
  schedule: "0 2 * * *"
EOF
