#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-03
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
# 실전과 동일하게 노드에서 etcdctl을 쓴다 — 없으면 etcd 이미지에서 꺼내 설치
node_etcdctl_ok || install_node_etcdctl \
  || die "control plane에 etcdctl을 설치하지 못했습니다. 'cka cluster doctor' 를 실행해 보세요."
# 이전 스냅샷 제거
docker exec cka-control-plane rm -f /var/lib/etcd/snapshot-cka.db >/dev/null 2>&1 || true
