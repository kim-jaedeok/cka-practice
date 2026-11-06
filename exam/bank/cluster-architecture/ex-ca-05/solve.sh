#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
CP="$(cka_cp_node)"

# The same commands the candidate runs in `kubectl debug node/... -- chroot /host`.
docker exec "$CP" sh -c '
  mkdir -p /var/lib/etcd-backup
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd-backup/pre-upgrade.db' >/dev/null 2>&1

mkdir -p "$CKA_WORK_DIR/ex-ca-05"
docker exec "$CP" etcdutl snapshot status /var/lib/etcd-backup/pre-upgrade.db -w json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["revision"])' \
  > "$CKA_WORK_DIR/ex-ca-05/revision.txt"
