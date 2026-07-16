#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-03

criterion 2 "control plane에 snapshot-cka.db 파일 존재" \
  "node_exec cka-control-plane 'test -s /var/lib/etcd/snapshot-cka.db'"

criterion 3 "스냅샷이 유효함 (etcdutl snapshot status 성공)" \
  "kctx -n kube-system exec etcd-cka-control-plane -- etcdutl snapshot status /var/lib/etcd/snapshot-cka.db"

criterion 2 "status.txt에 스냅샷 검증 출력 저장" \
  "file_exists \"\$CKA_WORK_DIR/ca-03/status.txt\" && \
   file_contains \"\$CKA_WORK_DIR/ca-03/status.txt\" '[0-9a-f]{8}|HASH|hash'"

grade_finish
