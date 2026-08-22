#!/usr/bin/env bash
# Adversarial fixture: replacing the setup-provided source with a new valid
# snapshot and restoring that replacement must not receive full credit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx delete namespace ca04-source-tamper --ignore-not-found --wait=true \
  --timeout=90s >/dev/null 2>&1 || true
kctx create namespace ca04-source-tamper >/dev/null
kctx label namespace ca04-source-tamper "$CKA_LABEL_KEY=ca-04" --overwrite >/dev/null
kctx -n ca04-source-tamper create configmap changed-after-setup \
  --from-literal=value=tampered >/dev/null

docker exec cka-control-plane etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-replacement.db >/dev/null
docker exec cka-control-plane sh -c '
  set -e
  test ! -L /var/lib/etcd/restore-drill
  rm -rf -- /var/lib/etcd/restore-drill
  mv -f /var/lib/etcd/snapshot-replacement.db /var/lib/etcd/snapshot-restore-src.db
  etcdutl snapshot restore /var/lib/etcd/snapshot-restore-src.db \
    --data-dir=/var/lib/etcd/restore-drill >/dev/null
'
