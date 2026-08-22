#!/usr/bin/env bash
# Cluster-free recovery contract for ts-13 generation-bound manifest backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

FIXTURE_ROOT="$TMP/fixture"
FIXTURE_QDIR="$FIXTURE_ROOT/questions/troubleshooting/ts-13"
FIXTURE_STATE="$FIXTURE_ROOT/state"
FIXTURE_LIVE_ETCD="$FIXTURE_ROOT/live-etcd.yaml"
FIXTURE_LIVE_API="$FIXTURE_ROOT/live-apiserver.yaml"
FIXTURE_LOG="$FIXTURE_ROOT/docker.log"
mkdir -p "$FIXTURE_QDIR" "$FIXTURE_ROOT/lib" "$FIXTURE_STATE/backup"
cp "$ROOT/questions/troubleshooting/ts-13/setup.sh" "$FIXTURE_QDIR/setup.sh"
cp "$ROOT/questions/troubleshooting/ts-13/teardown.sh" "$FIXTURE_QDIR/teardown.sh"

cat > "$FIXTURE_ROOT/lib/common.sh" <<'STUB'
CKA_ROOT="$FIXTURE_ROOT"
CKA_STATE_DIR="$FIXTURE_STATE"
CKA_CLUSTER_NAME=cka

info() { :; }
err() { printf '%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
require_cluster() { :; }
node_etcdctl_ok() { :; }

manifests_healthy() {
  grep -q -- '--listen-client-urls=https://127.0.0.1:2379,' "$FIXTURE_LIVE_ETCD" \
    && grep -qx -- '    - --etcd-servers=https://127.0.0.1:2379' "$FIXTURE_LIVE_API"
}

kctx() {
  if [ "${1:-}" = wait ]; then
    return 0
  fi
  [ "${1:-}" = get ] || return 98
  if manifests_healthy; then
    printf 'ok\n'
    return 0
  fi
  return 1
}

docker() {
  local input=0 target command script path
  if [ "${1:-}" = container ] && [ "${2:-}" = inspect ]; then
    printf '%s|/cka-control-plane|cka|control-plane|true|1|%s|END\n' \
      "$FAKE_NODE_ID" "$FAKE_NODE_IP"
    return 0
  fi
  [ "${1:-}" = exec ] || return 98
  shift
  if [ "${1:-}" = -i ]; then
    input=1
    shift
  fi
  target="${1:-}"
  shift
  [ "$target" = "$FAKE_NODE_ID" ] || return 97
  command="${1:-}"
  shift
  printf 'exec:%s:%s\n' "$target" "$command" >> "$FIXTURE_LOG"

  case "$command" in
    cat)
      path="${1:-}"
      case "$path" in
        /etc/kubernetes/manifests/etcd.yaml) cat "$FIXTURE_LIVE_ETCD" ;;
        /etc/kubernetes/manifests/kube-apiserver.yaml) cat "$FIXTURE_LIVE_API" ;;
        *) return 98 ;;
      esac
      ;;
    sha256sum)
      path="${1:-}"
      case "$path" in
        /etc/kubernetes/manifests/etcd.yaml) sha256sum "$FIXTURE_LIVE_ETCD" ;;
        /etc/kubernetes/manifests/kube-apiserver.yaml) sha256sum "$FIXTURE_LIVE_API" ;;
        *) return 98 ;;
      esac
      ;;
    sh)
      script="${2:-}"
      if [ "$input" -eq 1 ]; then
        if [[ "$script" == *ts-13-etcd.yaml.restore* ]]; then
          cat > "$FIXTURE_LIVE_ETCD"
          printf 'restore:etcd:%s\n' "$target" >> "$FIXTURE_LOG"
        elif [[ "$script" == *ts-13-apiserver.yaml.restore* ]]; then
          cat > "$FIXTURE_LIVE_API"
          printf 'restore:api:%s\n' "$target" >> "$FIXTURE_LOG"
        else
          return 98
        fi
      elif [[ "$script" == *'127.0.0.1:12379'* ]]; then
        # A setup may not mutate until the complete owner record is visible.
        grep -qx 'schema=1' "$FIXTURE_STATE/backup/ts-13/owner" \
          && grep -qx "container_id=$FAKE_NODE_ID" "$FIXTURE_STATE/backup/ts-13/owner" \
          && grep -qx "kind_ip=$FAKE_NODE_IP" "$FIXTURE_STATE/backup/ts-13/owner" \
          || return 96
        sed -i 's/127.0.0.1:2379,/127.0.0.1:12379,/' "$FIXTURE_LIVE_ETCD"
        sed -i 's/127.0.0.1:2379/127.0.0.1:22379/' "$FIXTURE_LIVE_API"
        printf 'mutate:%s\n' "$target" >> "$FIXTURE_LOG"
      else
        manifests_healthy
      fi
      ;;
    *) return 98 ;;
  esac
}
STUB

export FIXTURE_ROOT FIXTURE_STATE FIXTURE_LIVE_ETCD FIXTURE_LIVE_API FIXTURE_LOG
ORIGINAL_ID="$(printf 'a%.0s' {1..64})"
REPLACEMENT_ID="$(printf 'b%.0s' {1..64})"
ORIGINAL_IP=172.18.0.3
REPLACEMENT_IP=172.18.0.7

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

reset_case() {
  rm -rf -- "$FIXTURE_STATE/backup/ts-13"
  mkdir -p "$FIXTURE_STATE/backup"
  cat > "$FIXTURE_LIVE_ETCD" <<'EOF_ETCD'
    - --listen-client-urls=https://127.0.0.1:2379,https://172.18.0.3:2379
EOF_ETCD
  cat > "$FIXTURE_LIVE_API" <<'EOF_API'
    - --etcd-servers=https://127.0.0.1:2379
EOF_API
  : > "$FIXTURE_LOG"
  export FAKE_NODE_ID="$ORIGINAL_ID" FAKE_NODE_IP="$ORIGINAL_IP"
}

run_setup() {
  CKA_STATE_DIR="$FIXTURE_STATE" bash "$FIXTURE_QDIR/setup.sh"
}

run_teardown() {
  CKA_STATE_DIR="$FIXTURE_STATE" bash "$FIXTURE_QDIR/teardown.sh"
}

reset_case
if run_setup \
    && grep -qx 'schema=1' "$FIXTURE_STATE/backup/ts-13/owner" \
    && grep -qx "container_id=$ORIGINAL_ID" "$FIXTURE_STATE/backup/ts-13/owner" \
    && grep -qx "kind_ip=$ORIGINAL_IP" "$FIXTURE_STATE/backup/ts-13/owner" \
    && grep -qx "mutate:$ORIGINAL_ID" "$FIXTURE_LOG"; then
  pass 'setup publishes the full-ID/IP owner before manifest mutation'
else
  fail 'setup publishes the full-ID/IP owner before manifest mutation'
fi

if run_teardown \
    && grep -q -- '--listen-client-urls=https://127.0.0.1:2379,' "$FIXTURE_LIVE_ETCD" \
    && grep -qx -- '    - --etcd-servers=https://127.0.0.1:2379' "$FIXTURE_LIVE_API" \
    && [ ! -e "$FIXTURE_STATE/backup/ts-13/owner" ] \
    && [ ! -e "$FIXTURE_STATE/backup/ts-13/etcd.yaml" ] \
    && [ ! -e "$FIXTURE_STATE/backup/ts-13/kube-apiserver.yaml" ] \
    && grep -qx "restore:etcd:$ORIGINAL_ID" "$FIXTURE_LOG" \
    && grep -qx "restore:api:$ORIGINAL_ID" "$FIXTURE_LOG"; then
  pass 'same-owner interrupted state restores by immutable ID and is consumed'
else
  fail 'same-owner interrupted state restores by immutable ID and is consumed'
fi

reset_case
run_setup >/dev/null
export FAKE_NODE_ID="$REPLACEMENT_ID"
before_log="$(cat "$FIXTURE_LOG")"
if ! run_teardown >/dev/null 2>&1 \
    && [ "$(cat "$FIXTURE_LOG")" = "$before_log" ] \
    && grep -q -- '127.0.0.1:12379' "$FIXTURE_LIVE_ETCD" \
    && [ -e "$FIXTURE_STATE/backup/ts-13/owner" ]; then
  pass 'replacement container ID is rejected before any restore'
else
  fail 'replacement container ID is rejected before any restore'
fi

reset_case
run_setup >/dev/null
export FAKE_NODE_IP="$REPLACEMENT_IP"
before_log="$(cat "$FIXTURE_LOG")"
if ! run_teardown >/dev/null 2>&1 \
    && [ "$(cat "$FIXTURE_LOG")" = "$before_log" ] \
    && grep -q -- '127.0.0.1:12379' "$FIXTURE_LIVE_ETCD" \
    && [ -e "$FIXTURE_STATE/backup/ts-13/owner" ]; then
  pass 'changed control-plane IP is rejected before any restore'
else
  fail 'changed control-plane IP is rejected before any restore'
fi

reset_case
run_setup >/dev/null
rm -f -- "$FIXTURE_STATE/backup/ts-13/owner"
before_log="$(cat "$FIXTURE_LOG")"
if ! run_teardown >/dev/null 2>&1 \
    && [ "$(cat "$FIXTURE_LOG")" = "$before_log" ] \
    && grep -q -- '127.0.0.1:12379' "$FIXTURE_LIVE_ETCD"; then
  pass 'legacy backup without an owner record fails closed'
else
  fail 'legacy backup without an owner record fails closed'
fi

grep -Fq 'ln "$OWNER_TMP" "$OWNER_RECORD"' "$ROOT/questions/troubleshooting/ts-13/setup.sh" \
  && pass 'owner publication uses an atomic no-replace hard link' \
  || fail 'owner publication uses an atomic no-replace hard link'

printf '\nts-13 generation contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
