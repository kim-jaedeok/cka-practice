#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-14
NODE=cka-worker
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
CNI_BACKUP="$BACKUP_DIR/10-calico.conflist"
failed=0

[ "$BACKUP_DIR" = "$CKA_STATE_DIR/backup/$QID" ] \
  && [ ! -L "$CKA_STATE_DIR" ] \
  && [ ! -L "$CKA_STATE_DIR/backup" ] \
  && [ ! -L "$BACKUP_DIR" ] || exit 1

# Idempotent no-op path for a lab that has never established an incident.
if [ ! -e "$CNI_BACKUP" ] && [ ! -e "$CNI_BACKUP.sha256" ]; then
  docker exec -i "$NODE" sh -ceu '
    test -f /etc/cni/net.d/10-calico.conflist
    test ! -L /etc/cni/net.d/10-calico.conflist
    test ! -e /etc/cni/net.d/10-calico.conflist.cka-disabled
    systemctl enable --now containerd
  ' >/dev/null 2>&1 || exit 1
  kctx delete namespace runtime-check --ignore-not-found --wait=true --timeout=90s \
    >/dev/null 2>&1 || exit 1
  exit 0
fi

backup_valid() {
  local expected actual
  [ -f "$CNI_BACKUP" ] && [ ! -L "$CNI_BACKUP" ] \
    && [ -f "$CNI_BACKUP.sha256" ] && [ ! -L "$CNI_BACKUP.sha256" ] \
    || return 1
  read -r expected < "$CNI_BACKUP.sha256"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$CNI_BACKUP" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

if backup_valid; then
  docker exec -i "$NODE" sh -ceu '
    dir=/etc/cni/net.d
    target=$dir/10-calico.conflist
    disabled=$dir/10-calico.conflist.cka-disabled
    tmp=/tmp/cka-practice-ts-14-calico.conflist.restore
    test -d "$dir" && test ! -L "$dir"
    test ! -L "$target" && test ! -L "$disabled"
    test ! -L "$tmp"
    rm -f -- "$tmp"
    cat > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$target"
    rm -f -- "$disabled"
  ' < "$CNI_BACKUP" || failed=1
else
  failed=1
fi

docker exec "$NODE" systemctl enable --now containerd >/dev/null 2>&1 || failed=1

node_ready=0
for _ in $(seq 1 90); do
  if [ "$(kctx get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = True ]; then
    node_ready=1
    break
  fi
  sleep 2
done
[ "$node_ready" -eq 1 ] || failed=1

kctx delete namespace runtime-check --ignore-not-found --wait=true --timeout=90s \
  >/dev/null 2>&1 || failed=1
exit "$failed"
