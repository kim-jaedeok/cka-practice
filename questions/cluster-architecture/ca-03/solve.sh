#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-cka.db

mkdir -p "$CKA_WORK_DIR/ca-03"
kctx -n kube-system exec etcd-cka-control-plane -- etcdutl \
  snapshot status /var/lib/etcd/snapshot-cka.db -w table \
  > "$CKA_WORK_DIR/ca-03/status.txt"
