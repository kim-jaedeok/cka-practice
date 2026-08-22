#!/usr/bin/env bash
# Adversarial fixture: a valid decoy etcd already listening on the grader's
# loopback ports must never be mistaken for the candidate restore process.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

bash "$(dirname "${BASH_SOURCE[0]}")/near-miss.sh"
docker exec cka-control-plane sh -c '
  set -e
  rm -rf -- /var/lib/etcd/.cka-ca04-decoy
  etcdutl snapshot restore /var/lib/etcd/snapshot-restore-src.db \
    --data-dir=/var/lib/etcd/.cka-ca04-decoy >/dev/null
  etcd \
    --name default \
    --data-dir=/var/lib/etcd/.cka-ca04-decoy \
    --listen-client-urls=http://127.0.0.1:12379 \
    --advertise-client-urls=http://127.0.0.1:12379 \
    --listen-peer-urls=http://127.0.0.1:12380 \
    >/var/tmp/cka-ca04-decoy.log 2>&1 &
  printf "%s\n" "$!" > /run/cka-ca04-decoy.pid
'

ready=0
for _ in $(seq 1 30); do
  if docker exec cka-control-plane etcdctl \
      --endpoints=http://127.0.0.1:12379 --command-timeout=1s \
      endpoint health >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" -eq 1 ] || die "ca-04 decoy etcd가 기동하지 않았습니다."
