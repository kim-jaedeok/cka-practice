#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-13
NODE=cka-control-plane
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
ETCD_BACKUP="$BACKUP_DIR/etcd.yaml"
API_BACKUP="$BACKUP_DIR/kube-apiserver.yaml"
OWNER_RECORD="$BACKUP_DIR/owner"
OWNER_SCHEMA=1
CURRENT_NODE_ID=""
CURRENT_NODE_IP=""
OWNER_NODE_ID=""
OWNER_NODE_IP=""
failed=0

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

load_owner_record() {
  local ip_line
  local -a lines=()
  [ -f "$OWNER_RECORD" ] && [ ! -L "$OWNER_RECORD" ] || return 1
  mapfile -t lines < "$OWNER_RECORD" || return 1
  [ "${#lines[@]}" -eq 3 ] \
    && [ "${lines[0]}" = "schema=$OWNER_SCHEMA" ] \
    && [[ "${lines[1]}" =~ ^container_id=([0-9a-f]{64})$ ]] \
    || return 1
  OWNER_NODE_ID="${BASH_REMATCH[1]}"
  ip_line="${lines[2]}"
  [[ "$ip_line" == kind_ip=* ]] || return 1
  OWNER_NODE_IP="${ip_line#kind_ip=}"
  [ -n "$OWNER_NODE_IP" ] \
    && [[ "$OWNER_NODE_IP" != *"|"* ]] \
    && [[ "$OWNER_NODE_IP" != *[[:space:]]* ]]
}

owner_matches_current_node() {
  load_owner_record \
    && capture_current_node_identity \
    && [ "$OWNER_NODE_ID" = "$CURRENT_NODE_ID" ] \
    && [ "$OWNER_NODE_IP" = "$CURRENT_NODE_IP" ]
}

safe_backup_dir || exit 1

# A never-started or completely cleaned lab has no owned state to restore.
# Succeed only when the live control-plane baseline is independently healthy.
if [ ! -e "$ETCD_BACKUP" ] && [ ! -e "$ETCD_BACKUP.sha256" ] \
    && [ ! -e "$API_BACKUP" ] && [ ! -e "$API_BACKUP.sha256" ] \
    && [ ! -e "$OWNER_RECORD" ] && [ ! -e "$BACKUP_DIR/active" ]; then
  capture_current_node_identity || exit 1
  docker exec "$CURRENT_NODE_ID" sh -ceu '
    grep -q -- "--listen-client-urls=https://127.0.0.1:2379," /etc/kubernetes/manifests/etcd.yaml
    grep -qx -- "    - --etcd-servers=https://127.0.0.1:2379" /etc/kubernetes/manifests/kube-apiserver.yaml
  ' >/dev/null 2>&1 \
    && kctx get --raw=/readyz --request-timeout=3s >/dev/null 2>&1
  exit $?
fi

# This check is deliberately before checksum reads and every docker exec that
# can write a manifest. A recreated control-plane may reuse the same name but
# must never receive a backup owned by another immutable ID or previous IP.
if ! owner_matches_current_node; then
  err "Refusing ts-13 restore: backup owner does not match the current control-plane ID and IP."
  exit 1
fi
NODE_TARGET="$CURRENT_NODE_ID"

backup_valid() {
  local file="$1" expected actual
  [ -f "$file" ] && [ ! -L "$file" ] && [ -f "$file.sha256" ] && [ ! -L "$file.sha256" ] \
    || return 1
  read -r expected < "$file.sha256"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

node_manifest_matches_backup() { # node_manifest_matches_backup <node-path> <backup-file>
  local node_path="$1" backup="$2" expected checksum_line actual
  read -r expected < "$backup.sha256" || return 1
  checksum_line="$(docker exec "$NODE_TARGET" sha256sum "$node_path" 2>/dev/null)" || return 1
  actual="${checksum_line%% *}"
  [ "$actual" = "$expected" ]
}

# Validate the complete restore set before changing either manifest.
backup_valid "$ETCD_BACKUP" && backup_valid "$API_BACKUP" || exit 1

if ! node_manifest_matches_backup /etc/kubernetes/manifests/etcd.yaml "$ETCD_BACKUP"; then
  docker exec -i "$NODE_TARGET" sh -ceu '
    test -d /etc/kubernetes/manifests
    test ! -L /etc/kubernetes/manifests
    test ! -L /etc/kubernetes/manifests/etcd.yaml
    tmp=/tmp/cka-practice-ts-13-etcd.yaml.restore
    test ! -L "$tmp"
    rm -f -- "$tmp"
    cat > "$tmp"
    grep -q -- "--listen-client-urls=https://127.0.0.1:2379," "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" /etc/kubernetes/manifests/etcd.yaml
    ' < "$ETCD_BACKUP" || failed=1
fi

if ! node_manifest_matches_backup /etc/kubernetes/manifests/kube-apiserver.yaml "$API_BACKUP"; then
  docker exec -i "$NODE_TARGET" sh -ceu '
    test -d /etc/kubernetes/manifests
    test ! -L /etc/kubernetes/manifests
    test ! -L /etc/kubernetes/manifests/kube-apiserver.yaml
    tmp=/tmp/cka-practice-ts-13-apiserver.yaml.restore
    test ! -L "$tmp"
    rm -f -- "$tmp"
    cat > "$tmp"
    grep -qx -- "    - --etcd-servers=https://127.0.0.1:2379" "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" /etc/kubernetes/manifests/kube-apiserver.yaml
    ' < "$API_BACKUP" || failed=1
fi

if [ "$failed" -eq 0 ]; then
  api_ready=0
  for _ in $(seq 1 90); do
    if kctx get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; then
      api_ready=1
      break
    fi
    sleep 2
  done
  [ "$api_ready" -eq 1 ] || failed=1
fi

# Revalidate both the name binding and restored contents before deleting the
# only recovery record. Successful cleanup removes all generation-bound data,
# so it cannot become a stale restore source for a later KIND cluster.
if [ "$failed" -eq 0 ]; then
  owner_matches_current_node \
    && [ "$CURRENT_NODE_ID" = "$NODE_TARGET" ] \
    && node_manifest_matches_backup /etc/kubernetes/manifests/etcd.yaml "$ETCD_BACKUP" \
    && node_manifest_matches_backup /etc/kubernetes/manifests/kube-apiserver.yaml "$API_BACKUP" \
    || failed=1
fi

if [ "$failed" -eq 0 ]; then
  rm -f -- "$BACKUP_DIR/active" "$OWNER_RECORD" \
    "$ETCD_BACKUP.sha256" "$API_BACKUP.sha256" \
    "$ETCD_BACKUP" "$API_BACKUP" || failed=1
fi

exit "$failed"
