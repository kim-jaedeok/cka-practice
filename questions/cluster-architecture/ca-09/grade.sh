#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-09

criterion 2 "crds.txt에 클러스터 CRD 목록 저장 (backups.stable.example.com 포함)" \
  "file_contains \"\$CKA_WORK_DIR/ca-09/crds.txt\" 'backups.stable.example.com' && \
   file_contains \"\$CKA_WORK_DIR/ca-09/crds.txt\" 'gateways.gateway.networking.k8s.io'"

criterion 1 "spec.txt에 kubectl explain 출력 저장 (source/schedule 필드)" \
  "file_contains \"\$CKA_WORK_DIR/ca-09/spec.txt\" 'source' && \
   file_contains \"\$CKA_WORK_DIR/ca-09/spec.txt\" 'schedule'"

criterion 1 "커스텀 리소스 db-backup이 operators에 존재" \
  "res_exists backup.stable.example.com db-backup operators"

criterion 2 "spec.source=/data, spec.schedule='0 2 * * *'" \
  "jp_eq backup.stable.example.com db-backup operators '{.spec.source}' /data && \
   jp_eq backup.stable.example.com db-backup operators '{.spec.schedule}' '0 2 * * *'"

grade_finish
