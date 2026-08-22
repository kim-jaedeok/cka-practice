#!/usr/bin/env bash
# Adversarial fixture: a snapshot DB with its trailing checksum removed plus an
# arbitrary WAL-looking file must not be accepted as a real etcdutl restore.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec cka-control-plane sh -c '
  set -e
  test ! -L /var/lib/etcd/restore-drill
  rm -rf -- /var/lib/etcd/restore-drill
  mkdir -p /var/lib/etcd/restore-drill/member/snap \
    /var/lib/etcd/restore-drill/member/wal
  head -c -32 /var/lib/etcd/snapshot-restore-src.db \
    > /var/lib/etcd/restore-drill/member/snap/db
  printf fake-wal \
    > /var/lib/etcd/restore-drill/member/wal/0000000000000000-0000000000000000.wal
'
