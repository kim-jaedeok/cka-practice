#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# 1. (control plane 노드) 스냅샷 생성
ssh cka-control-plane "etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-cka.db"

# 2. 검증 출력을 작업 머신의 파일로 저장 (ssh 원격 실행 결과를 리다이렉트)
mkdir -p "$CKA_WORK_DIR/ca-03"
ssh cka-control-plane "etcdutl snapshot status /var/lib/etcd/snapshot-cka.db -w table" \
  > "$CKA_WORK_DIR/ca-03/status.txt"
