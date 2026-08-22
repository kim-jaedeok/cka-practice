#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-04

ca04_source_snapshot_fingerprint() {
  local source_sha source_json
  source_sha="$(docker exec cka-control-plane sha256sum \
    /var/lib/etcd/snapshot-restore-src.db 2>/dev/null | awk '{print $1}')" \
    || return 1
  source_json="$(docker exec cka-control-plane etcdutl --write-out=json snapshot status \
    /var/lib/etcd/snapshot-restore-src.db 2>/dev/null)" || return 1
  [ -n "$source_sha" ] || return 1
  python3 -c '
import json, sys
value = json.loads(sys.argv[2])
if isinstance(value, list):
    if len(value) != 1:
        raise SystemExit(1)
    value = value[0]
revision = value.get("revision")
total_key = value.get("totalKey")
if revision is None or total_key is None:
    raise SystemExit(1)
print(f"{sys.argv[1]}|{revision}|{total_key}")
' "$source_sha" "$source_json"
}

ca04_source_snapshot_unchanged() {
  local expected current fingerprint
  fingerprint="$CKA_STATE_DIR/question-data/ca-04/source-fingerprint"
  [ -s "$fingerprint" ] || return 2
  expected="$(tr -d '\r\n' < "$fingerprint")" || return 2
  current="$(ca04_source_snapshot_fingerprint)" || return 1
  [ -n "$expected" ] && [ "$current" = "$expected" ]
}

ca04_restore_matches_source() {
  local source_json restored_json source_sha restored_sha
  _python3_require || return $?
  source_json="$(docker exec cka-control-plane etcdutl --write-out=json snapshot status \
    /var/lib/etcd/snapshot-restore-src.db 2>/dev/null)" || return 1
  restored_json="$(docker exec cka-control-plane etcdutl --write-out=json snapshot status \
    /var/lib/etcd/restore-drill/member/snap/db 2>/dev/null)" || return 1
  source_sha="$(docker exec cka-control-plane sha256sum \
    /var/lib/etcd/snapshot-restore-src.db 2>/dev/null | awk '{print $1}')" || return 1
  restored_sha="$(docker exec cka-control-plane sha256sum \
    /var/lib/etcd/restore-drill/member/snap/db 2>/dev/null | awk '{print $1}')" || return 1
  [ -n "$source_sha" ] && [ -n "$restored_sha" ] && [ "$source_sha" != "$restored_sha" ] \
    || return 1
  python3 -c '
import json, sys

def status(raw):
    value = json.loads(raw)
    if isinstance(value, list):
        if len(value) != 1:
            raise ValueError("unexpected status list")
        value = value[0]
    return value

source = status(sys.argv[1])
restored = status(sys.argv[2])
ok = (
    source.get("revision") == restored.get("revision")
    and source.get("totalKey") == restored.get("totalKey")
    and source.get("revision") is not None
    and source.get("totalKey") is not None
)
raise SystemExit(0 if ok else 1)
' "$source_json" "$restored_json"
}

ca04_probe_ports_unused() {
  docker exec cka-control-plane sh -c '
    for port_hex in "$@"; do
      if awk -v suffix=":$port_hex" \
          '\''$2 ~ (suffix "$") && $4 == "0A" { found=1 } END { exit(found ? 0 : 1) }'\'' \
          /proc/net/tcp /proc/net/tcp6; then
        exit 1
      fi
    done
  ' cka-ca04-port-check 305B 305C >/dev/null 2>&1
}

ca04_probe_process_owns_ports() { # <hard-coded data-dir>
  local data_dir="$1"
  docker exec cka-control-plane sh -c '
    data_dir="$1"; shift
    pid=$(cat /run/cka-ca04-etcd.pid 2>/dev/null || true)
    case "$pid" in ""|*[!0-9]*) exit 1 ;; esac
    kill -0 "$pid" 2>/dev/null || exit 1
    cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmdline" in
      *etcd*"--data-dir=$data_dir"*) ;;
      *) exit 1 ;;
    esac
    for port_hex in "$@"; do
      inodes=$(awk -v suffix=":$port_hex" \
        '\''$2 ~ (suffix "$") && $4 == "0A" { print $10 }'\'' \
        /proc/net/tcp /proc/net/tcp6)
      [ -n "$inodes" ] || exit 1
      owned=0
      for fd in /proc/"$pid"/fd/*; do
        link=$(readlink "$fd" 2>/dev/null || true)
        for inode in $inodes; do
          [ "$link" = "socket:[$inode]" ] && owned=1
        done
      done
      [ "$owned" -eq 1 ] || exit 1
    done
  ' cka-ca04-owner-check "$data_dir" 305B 305C >/dev/null 2>&1
}

ca04_stop_restore_probe() {
  docker exec cka-control-plane sh -c '
    pidfile=/run/cka-ca04-etcd.pid
    if [ -r "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      case "$pid" in
        ""|*[!0-9]*) ;;
        *)
          cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
          case "$cmdline" in
            *etcd*--data-dir=/var/lib/etcd/restore-drill*|\
            *etcd*--data-dir=/var/lib/etcd/.cka-ca04-reference*)
              kill "$pid" 2>/dev/null || true
              i=0
              while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
                sleep 0.1
                i=$((i + 1))
              done
              kill -KILL "$pid" 2>/dev/null || true
              ;;
          esac
          ;;
      esac
    fi
    rm -f "$pidfile"
  ' >/dev/null 2>&1
}

ca04_stop_decoy_probe() {
  docker exec cka-control-plane sh -c '
    pidfile=/run/cka-ca04-decoy.pid
    if [ -r "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      case "$pid" in
        ""|*[!0-9]*) ;;
        *)
          cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
          case "$cmdline" in
            *etcd*--data-dir=/var/lib/etcd/.cka-ca04-decoy*)
              kill "$pid" 2>/dev/null || true
              i=0
              while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
                sleep 0.1
                i=$((i + 1))
              done
              kill -KILL "$pid" 2>/dev/null || true
              ;;
          esac
          ;;
      esac
    fi
    rm -f "$pidfile"
    rm -rf -- /var/lib/etcd/.cka-ca04-decoy
  ' >/dev/null 2>&1
}

# 복원 data-dir을 별도 loopback port에서 잠깐 기동하고 keyspace hash와 membership을
# 읽는다. 호출 결과는 CA04_PROBE_HASH에 저장되며 probe는 항상 종료한다.
ca04_probe_data_dir() { # <hard-coded data-dir>
  local data_dir="$1" hash_json="" member_json="" attempt result=1
  case "$data_dir" in
    /var/lib/etcd/restore-drill|/var/lib/etcd/.cka-ca04-reference) ;;
    *) return 1 ;;
  esac
  CA04_PROBE_HASH=""
  ca04_stop_restore_probe || return 1
  ca04_probe_ports_unused || return 1
  docker exec cka-control-plane sh -c "
    set -e
    command -v etcd >/dev/null
    rm -f /var/tmp/cka-ca04-etcd.log
    etcd \
      --name default \
      --data-dir='$data_dir' \
      --listen-client-urls=http://127.0.0.1:12379 \
      --advertise-client-urls=http://127.0.0.1:12379 \
      --listen-peer-urls=http://127.0.0.1:12380 \
      >/var/tmp/cka-ca04-etcd.log 2>&1 &
    printf '%s\n' \"\$!\" > /run/cka-ca04-etcd.pid
  " >/dev/null 2>&1 || return 1

  for attempt in $(seq 1 15); do
    if docker exec cka-control-plane etcdctl \
        --endpoints=http://127.0.0.1:12379 \
        --command-timeout=1s endpoint health >/dev/null 2>&1 \
        && ca04_probe_process_owns_ports "$data_dir"; then
      hash_json="$(docker exec cka-control-plane etcdctl \
        --endpoints=http://127.0.0.1:12379 \
        --command-timeout=2s --write-out=json endpoint hashkv 2>/dev/null)" || hash_json=""
      member_json="$(docker exec cka-control-plane etcdctl \
        --endpoints=http://127.0.0.1:12379 \
        --command-timeout=2s --write-out=json member list 2>/dev/null)" || member_json=""
      if [ -n "$hash_json" ] && [ -n "$member_json" ] \
          && ca04_probe_process_owns_ports "$data_dir"; then
        CA04_PROBE_HASH="$(python3 -c '
import json, sys
hashes = json.loads(sys.argv[1])
members = json.loads(sys.argv[2]).get("members", [])
if len(hashes) != 1 or len(members) != 1 or not members[0].get("name"):
    raise SystemExit(1)
item = hashes[0].get("HashKV", {})
values = (item.get("hash"), item.get("hash_revision"), item.get("compact_revision"))
if values[0] is None or values[1] is None:
    raise SystemExit(1)
print("|".join(str(value) for value in values))
' "$hash_json" "$member_json")" && result=0
      fi
      break
    fi
    sleep 0.2
  done
  ca04_stop_restore_probe || result=1
  return "$result"
}

# 후보 data-dir과 같은 source snapshot을 grader-owned 경로에 독립 복원한다.
# 두 디렉터리가 모두 실제 etcd member로 기동되고 live MVCC keyspace hash가 같아야
# 통과하므로, checksum을 자른 DB + 임의 WAL 파일 조합은 통과하지 못한다.
ca04_restored_member_matches_reference() {
  local reference_hash candidate_hash result=1
  docker exec cka-control-plane rm -rf -- /var/lib/etcd/.cka-ca04-reference \
    >/dev/null 2>&1 || return 1
  if docker exec cka-control-plane etcdutl snapshot restore \
      /var/lib/etcd/snapshot-restore-src.db \
      --data-dir=/var/lib/etcd/.cka-ca04-reference >/dev/null 2>&1 \
      && ca04_probe_data_dir /var/lib/etcd/.cka-ca04-reference; then
    reference_hash="$CA04_PROBE_HASH"
    if ca04_probe_data_dir /var/lib/etcd/restore-drill; then
      candidate_hash="$CA04_PROBE_HASH"
      [ -n "$reference_hash" ] && [ "$candidate_hash" = "$reference_hash" ] && result=0
    fi
  fi
  ca04_stop_restore_probe || result=1
  docker exec cka-control-plane rm -rf -- /var/lib/etcd/.cka-ca04-reference \
    >/dev/null 2>&1 || result=1
  return "$result"
}

ca04_cleanup_probe() {
  local result=0
  ca04_stop_restore_probe || result=1
  ca04_stop_decoy_probe || result=1
  docker exec cka-control-plane rm -rf -- /var/lib/etcd/.cka-ca04-reference \
    >/dev/null 2>&1 || result=1
  return "$result"
}

trap ca04_cleanup_probe EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_python3_require || true
[ -s "$CKA_STATE_DIR/question-data/ca-04/source-fingerprint" ] \
  || grade_invalid "ca-04 trusted source snapshot fingerprint missing" || true

criterion 3 "restore-drill이 source snapshot과 같은 revision/keyspace로 실제 복원됨" \
  "ca04_source_snapshot_unchanged && \
   node_exec cka-control-plane \
     'test -d /var/lib/etcd/restore-drill/member/snap && \
      test -d /var/lib/etcd/restore-drill/member/wal && \
      find /var/lib/etcd/restore-drill/member/wal -type f -size +0c -print -quit | grep -q .' && \
   ca04_restore_matches_source && \
   ca04_restored_member_matches_reference"

criterion 1 "restore된 DB 파일이 비어 있지 않고 etcdutl status 검증을 통과" \
  "node_exec cka-control-plane \
     'test -s /var/lib/etcd/restore-drill/member/snap/db && \
      etcdutl snapshot status /var/lib/etcd/restore-drill/member/snap/db -w json'"

criterion 1 "소스 스냅샷 파일이 그대로 보존됨" \
  "node_exec cka-control-plane 'test -s /var/lib/etcd/snapshot-restore-src.db' && \
   ca04_source_snapshot_unchanged"

criterion 1 "실행 중인 etcd는 원래 data-dir를 사용하며 클러스터가 정상" \
  "pod_ready kube-system etcd-cka-control-plane && \
   container_argv_has pod etcd-cka-control-plane kube-system etcd --data-dir=/var/lib/etcd && \
   ! container_argv_has pod etcd-cka-control-plane kube-system etcd --data-dir=/var/lib/etcd/restore-drill && \
   cluster_ready"

grade_finish
