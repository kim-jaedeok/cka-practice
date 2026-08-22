#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

NODE=cka-control-plane

docker exec "$NODE" sh -ceu '
  sed -i "s#--listen-client-urls=https://127.0.0.1:12379,#--listen-client-urls=https://127.0.0.1:2379,#" \
    /etc/kubernetes/manifests/etcd.yaml
  sed -i "s#--etcd-servers=https://127.0.0.1:22379#--etcd-servers=https://127.0.0.1:2379#" \
    /etc/kubernetes/manifests/kube-apiserver.yaml
'

for _ in $(seq 1 90); do
  kctx get --raw=/readyz --request-timeout=2s >/dev/null 2>&1 && break
  sleep 2
done
[ "$(kctx get --raw=/readyz --request-timeout=3s 2>/dev/null)" = ok ]

docker exec "$NODE" sh -ceu '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    endpoint health
' >/dev/null
