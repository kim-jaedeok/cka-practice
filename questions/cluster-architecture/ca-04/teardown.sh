#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# Hard-coded lab-owned paths only. Removing a symlink does not traverse its target.
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
'
docker exec cka-control-plane rm -rf -- \
  /var/lib/etcd/restore-drill /var/lib/etcd/.cka-ca04-reference \
  /var/lib/etcd/.cka-ca04-decoy
docker exec cka-control-plane rm -f -- /var/lib/etcd/snapshot-restore-src.db
rm -f -- "$CKA_STATE_DIR/question-data/ca-04/source-fingerprint"
rmdir "$CKA_STATE_DIR/question-data/ca-04" 2>/dev/null || true
