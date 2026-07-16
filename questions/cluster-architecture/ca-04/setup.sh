#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-04
require_cluster
cleanup_question "$QID"
# 이전 드릴 디렉토리 제거 + 소스 스냅샷 준비
docker exec cka-control-plane rm -rf /var/lib/etcd/restore-drill >/dev/null 2>&1 || true
kctx -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-restore-src.db >/dev/null
