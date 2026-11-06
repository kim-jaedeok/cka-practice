#!/usr/bin/env bash
# Near-miss fixture: the snapshot is right, but the hash column of the status
# table was saved instead of the revision.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
CP="$(cka_cp_node)"

docker exec "$CP" sh -c '
  mkdir -p /var/lib/etcd-backup
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
    --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
    snapshot save /var/lib/etcd-backup/pre-upgrade.db' >/dev/null 2>&1

mkdir -p "$CKA_WORK_DIR/ex-ca-05"
docker exec "$CP" etcdutl snapshot status /var/lib/etcd-backup/pre-upgrade.db -w json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])' \
  > "$CKA_WORK_DIR/ex-ca-05/revision.txt"
