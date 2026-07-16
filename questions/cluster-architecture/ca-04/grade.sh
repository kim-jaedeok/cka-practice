#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-04

criterion 3 "restore-drill 디렉토리에 member 구조 생성됨 (snap/wal)" \
  "node_exec cka-control-plane 'test -d /var/lib/etcd/restore-drill/member/snap && test -d /var/lib/etcd/restore-drill/member/wal'"

criterion 1 "restore된 DB 파일 존재" \
  "node_exec cka-control-plane 'ls /var/lib/etcd/restore-drill/member/snap/db'"

criterion 1 "소스 스냅샷 파일이 그대로 보존됨" \
  "node_exec cka-control-plane 'test -s /var/lib/etcd/snapshot-restore-src.db'"

criterion 1 "실행 중인 etcd는 건드리지 않음 (클러스터 정상)" \
  "pod_ready kube-system etcd-cka-control-plane && cluster_ready"

grade_finish
