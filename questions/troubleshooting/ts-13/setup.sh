#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-13
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE=cka-control-plane
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
ETCD_BACKUP="$BACKUP_DIR/etcd.yaml"
API_BACKUP="$BACKUP_DIR/kube-apiserver.yaml"
OWNER_RECORD="$BACKUP_DIR/owner"
OWNER_SCHEMA=1
SETUP_OK=0
CURRENT_NODE_ID=""
CURRENT_NODE_IP=""
ETCD_TMP=""
API_TMP=""
ETCD_SHA_TMP=""
API_SHA_TMP=""
OWNER_TMP=""
ACTIVE_TMP=""

safe_backup_dir() {
  [ "$BACKUP_DIR" = "$CKA_STATE_DIR/backup/$QID" ] \
    && [ ! -L "$CKA_STATE_DIR" ] \
    && [ ! -L "$CKA_STATE_DIR/backup" ] \
    && [ ! -L "$BACKUP_DIR" ]
}

capture_current_node_identity() {
  local record id name cluster role running network_count ip marker extra
  record="$(docker container inspect --format \
    '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.x-k8s.kind.cluster"}}|{{index .Config.Labels "io.x-k8s.kind.role"}}|{{.State.Running}}|{{len .NetworkSettings.Networks}}|{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}|END' \
    "$NODE" 2>/dev/null)" || return 1
  [ -n "$record" ] && [[ "$record" != *$'\n'* ]] || return 1
  IFS='|' read -r id name cluster role running network_count ip marker extra <<< "$record"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] \
    && [ "$name" = "/$NODE" ] \
    && [ "$cluster" = "$CKA_CLUSTER_NAME" ] \
    && [ "$role" = control-plane ] \
    && [ "$running" = true ] \
    && [ "$network_count" = 1 ] \
    && [ -n "$ip" ] \
    && [[ "$ip" != *"|"* ]] \
    && [[ "$ip" != *[[:space:]]* ]] \
    && [ "$marker" = END ] \
    && [ -z "${extra:-}" ] || return 1
  CURRENT_NODE_ID="$id"
  CURRENT_NODE_IP="$ip"
}

write_owner_record() {
  OWNER_TMP="$(mktemp "$BACKUP_DIR/.owner.XXXXXX")"
  printf 'schema=%s\ncontainer_id=%s\nkind_ip=%s\n' \
    "$OWNER_SCHEMA" "$CURRENT_NODE_ID" "$CURRENT_NODE_IP" > "$OWNER_TMP"
  chmod 0600 "$OWNER_TMP"
  # The hard-link publication is atomic and refuses to replace an existing
  # owner. The temporary name is removed only after ownership is published.
  ln "$OWNER_TMP" "$OWNER_RECORD"
  rm -f -- "$OWNER_TMP"
  OWNER_TMP=""
}

cleanup_local_temps() {
  local path
  for path in "$ETCD_TMP" "$API_TMP" "$ETCD_SHA_TMP" "$API_SHA_TMP" "$OWNER_TMP" "$ACTIVE_TMP"; do
    [ -n "$path" ] || continue
    case "$path" in
      "$BACKUP_DIR"/.*) [ ! -L "$path" ] && rm -f -- "$path" || true ;;
    esac
  done
  return 0
}

restore_on_failure() {
  local rc=$?
  trap - EXIT
  cleanup_local_temps
  if [ "$SETUP_OK" -ne 1 ]; then
    bash "$HERE/teardown.sh" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap restore_on_failure EXIT

# An interrupted previous attempt may have left the API offline. Restore only
# when its immutable owner record proves this is the same control-plane
# container generation and the same current KIND-network address.
if [ -e "$ETCD_BACKUP" ] || [ -e "$ETCD_BACKUP.sha256" ] \
    || [ -e "$API_BACKUP" ] || [ -e "$API_BACKUP.sha256" ] \
    || [ -e "$OWNER_RECORD" ] || [ -e "$BACKUP_DIR/active" ]; then
  bash "$HERE/teardown.sh"
fi
require_cluster

kctx wait --for=condition=Ready node --all --timeout=15s >/dev/null
[ "$(kctx get --raw=/readyz 2>/dev/null)" = ok ] \
  || die "API server baseline is not healthy."
node_etcdctl_ok || die "etcd, etcdctl, and etcdutl must be installed on $NODE."

capture_current_node_identity \
  || die "The current control-plane container identity or KIND-network IP is invalid."
TRANSACTION_NODE_ID="$CURRENT_NODE_ID"
TRANSACTION_NODE_IP="$CURRENT_NODE_IP"

docker exec "$TRANSACTION_NODE_ID" sh -ceu '
  test -f /etc/kubernetes/manifests/etcd.yaml
  test ! -L /etc/kubernetes/manifests/etcd.yaml
  test -f /etc/kubernetes/manifests/kube-apiserver.yaml
  test ! -L /etc/kubernetes/manifests/kube-apiserver.yaml
  test "$(grep -c -- "--listen-client-urls=https://127.0.0.1:2379," /etc/kubernetes/manifests/etcd.yaml)" -eq 1
  test "$(grep -c -- "--etcd-servers=https://127.0.0.1:2379" /etc/kubernetes/manifests/kube-apiserver.yaml)" -eq 1
' || die "Control-plane manifests do not match the expected healthy baseline."

mkdir -p "$BACKUP_DIR"
safe_backup_dir || die "Unsafe backup path: $BACKUP_DIR"
[ ! -e "$ETCD_BACKUP" ] && [ ! -e "$ETCD_BACKUP.sha256" ] \
  && [ ! -e "$API_BACKUP" ] && [ ! -e "$API_BACKUP.sha256" ] \
  && [ ! -e "$OWNER_RECORD" ] && [ ! -e "$BACKUP_DIR/active" ] \
  || die "Backup state already exists after recovery."

ETCD_TMP="$(mktemp "$BACKUP_DIR/.etcd.XXXXXX")"
API_TMP="$(mktemp "$BACKUP_DIR/.apiserver.XXXXXX")"
ETCD_SHA_TMP="$(mktemp "$BACKUP_DIR/.etcd-sha.XXXXXX")"
API_SHA_TMP="$(mktemp "$BACKUP_DIR/.apiserver-sha.XXXXXX")"
docker exec "$TRANSACTION_NODE_ID" cat /etc/kubernetes/manifests/etcd.yaml > "$ETCD_TMP"
docker exec "$TRANSACTION_NODE_ID" cat /etc/kubernetes/manifests/kube-apiserver.yaml > "$API_TMP"
sha256sum "$ETCD_TMP" | awk '{print $1}' > "$ETCD_SHA_TMP"
sha256sum "$API_TMP" | awk '{print $1}' > "$API_SHA_TMP"
chmod 0600 "$ETCD_TMP" "$API_TMP" "$ETCD_SHA_TMP" "$API_SHA_TMP"
mv -- "$ETCD_TMP" "$ETCD_BACKUP"; ETCD_TMP=""
mv -- "$API_TMP" "$API_BACKUP"; API_TMP=""
mv -- "$ETCD_SHA_TMP" "$ETCD_BACKUP.sha256"; ETCD_SHA_TMP=""
mv -- "$API_SHA_TMP" "$API_BACKUP.sha256"; API_SHA_TMP=""
write_owner_record

# Re-resolve the name immediately before mutation. If the name was rebound or
# Docker changed its address, leave the owned backup intact and fail closed.
capture_current_node_identity \
  && [ "$CURRENT_NODE_ID" = "$TRANSACTION_NODE_ID" ] \
  && [ "$CURRENT_NODE_IP" = "$TRANSACTION_NODE_IP" ] \
  || die "The control-plane container generation changed during setup."

# Break two independent links in the etcd -> API-server chain. sed -i writes
# through a temporary file and rename; no backup manifest is left in kubelet's
# watched manifest directory.
docker exec "$TRANSACTION_NODE_ID" sh -ceu '
  etcd=/etc/kubernetes/manifests/etcd.yaml
  api=/etc/kubernetes/manifests/kube-apiserver.yaml
  test ! -L "$etcd" && test ! -L "$api"
  sed -i "s#--listen-client-urls=https://127.0.0.1:2379,#--listen-client-urls=https://127.0.0.1:12379,#" "$etcd"
  test "$(grep -c -- "--listen-client-urls=https://127.0.0.1:12379," "$etcd")" -eq 1

  sed -i "s#--etcd-servers=https://127.0.0.1:2379#--etcd-servers=https://127.0.0.1:22379#" "$api"
  test "$(grep -c -- "--etcd-servers=https://127.0.0.1:22379" "$api")" -eq 1
'

# Fail closed unless kubelet has observed the outage. Every probe is bounded.
api_failed=0
for _ in $(seq 1 30); do
  if ! kctx get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; then
    api_failed=1
    break
  fi
  sleep 1
done
[ "$api_failed" -eq 1 ] || die "The API outage was not established."

ACTIVE_TMP="$(mktemp "$BACKUP_DIR/.active.XXXXXX")"
printf '%s\n' "$QID" > "$ACTIVE_TMP"
chmod 0600 "$ACTIVE_TMP"
mv -- "$ACTIVE_TMP" "$BACKUP_DIR/active"
ACTIVE_TMP=""
SETUP_OK=1
info "etcd and kube-apiserver endpoints are inconsistent; the API is offline."
