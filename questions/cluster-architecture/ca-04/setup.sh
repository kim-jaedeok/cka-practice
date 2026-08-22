#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-04
require_cluster
cleanup_question "$QID"
# 실전과 동일하게 노드에서 etcdctl/etcdutl을 쓴다 — 없으면 etcd 이미지에서 꺼내 설치
node_etcdctl_ok || install_node_etcdctl \
  || die "control plane에 etcdctl을 설치하지 못했습니다. 'cka cluster doctor' 를 실행해 보세요."
# 이전 채점이 강제 중단됐더라도 격리 probe를 먼저 멈춘 뒤 lab-owned path를 초기화한다.
docker exec cka-control-plane sh -c '
  if [ -r /run/cka-ca04-etcd.pid ]; then
    pid=$(cat /run/cka-ca04-etcd.pid 2>/dev/null || true)
    case "$pid" in
      ""|*[!0-9]*) ;;
      *)
        cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmdline" in
          *etcd*--data-dir=/var/lib/etcd/restore-drill*|\
          *etcd*--data-dir=/var/lib/etcd/.cka-ca04-reference*) kill "$pid" 2>/dev/null || true ;;
        esac
        ;;
    esac
  fi
  rm -f /run/cka-ca04-etcd.pid /var/tmp/cka-ca04-etcd.log
  if [ -r /run/cka-ca04-decoy.pid ]; then
    pid=$(cat /run/cka-ca04-decoy.pid 2>/dev/null || true)
    case "$pid" in
      ""|*[!0-9]*) ;;
      *)
        cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmdline" in
          *etcd*--data-dir=/var/lib/etcd/.cka-ca04-decoy*) kill "$pid" 2>/dev/null || true ;;
        esac
        ;;
    esac
  fi
  rm -f /run/cka-ca04-decoy.pid
' >/dev/null 2>&1 || true
# 이전 드릴 디렉토리 제거 + 소스 스냅샷 준비
docker exec cka-control-plane rm -rf \
  /var/lib/etcd/restore-drill /var/lib/etcd/.cka-ca04-reference \
  /var/lib/etcd/.cka-ca04-decoy >/dev/null 2>&1 || true
docker exec cka-control-plane etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-restore-src.db >/dev/null

# Preserve the exact setup-provided source identity outside the candidate node.
# The grader compares both bytes and semantic snapshot status against this file.
fingerprint_dir="$CKA_STATE_DIR/question-data/$QID"
fingerprint_tmp="$fingerprint_dir/.source-fingerprint.$$"
mkdir -p "$fingerprint_dir"
source_sha="$(docker exec cka-control-plane sha256sum \
  /var/lib/etcd/snapshot-restore-src.db | awk '{print $1}')"
source_status="$(docker exec cka-control-plane etcdutl --write-out=json snapshot status \
  /var/lib/etcd/snapshot-restore-src.db)"
normalized_status="$(python3 -c '
import json, sys
value = json.loads(sys.argv[1])
if isinstance(value, list):
    if len(value) != 1:
        raise SystemExit(1)
    value = value[0]
revision = value.get("revision")
total_key = value.get("totalKey")
if revision is None or total_key is None:
    raise SystemExit(1)
print(f"{revision}|{total_key}")
' "$source_status")"
[ -n "$source_sha" ] && [ -n "$normalized_status" ] \
  || die "ca-04 source snapshot fingerprint를 만들지 못했습니다."
printf '%s|%s\n' "$source_sha" "$normalized_status" > "$fingerprint_tmp"
mv -f "$fingerprint_tmp" "$fingerprint_dir/source-fingerprint"
