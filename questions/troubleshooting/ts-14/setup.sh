#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-14
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE=cka-worker
CNI=/etc/cni/net.d/10-calico.conflist
DISABLED=/etc/cni/net.d/10-calico.conflist.cka-disabled
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
CNI_BACKUP="$BACKUP_DIR/10-calico.conflist"
SETUP_OK=0

safe_backup_dir() {
  [ "$BACKUP_DIR" = "$CKA_STATE_DIR/backup/$QID" ] \
    && [ ! -L "$CKA_STATE_DIR" ] \
    && [ ! -L "$CKA_STATE_DIR/backup" ] \
    && [ ! -L "$BACKUP_DIR" ]
}

restore_on_failure() {
  local rc=$?
  trap - EXIT
  if [ "$SETUP_OK" -ne 1 ]; then
    bash "$HERE/teardown.sh" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap restore_on_failure EXIT

if [ -f "$CNI_BACKUP.sha256" ]; then
  bash "$HERE/teardown.sh"
fi
require_cluster
cleanup_question "$QID"
kctx wait --for=condition=Ready node --all --timeout=15s >/dev/null \
  || die "All nodes must be Ready before starting this lab."

[ "$(docker exec "$NODE" systemctl is-active containerd 2>/dev/null)" = active ] \
  || die "containerd baseline is not active on $NODE."
[ "$(docker exec "$NODE" systemctl is-enabled containerd 2>/dev/null)" = enabled ] \
  || die "containerd baseline is not enabled on $NODE."
docker exec "$NODE" sh -c "test -d /etc/cni/net.d && test ! -L /etc/cni/net.d && test -f '$CNI' && test ! -L '$CNI' && test ! -e '$DISABLED'" \
  || die "CNI baseline is unsafe or already modified on $NODE."
docker exec "$NODE" sh -c 'crictl info >/dev/null' \
  || die "CRI baseline is not responding on $NODE."

mkdir -p "$BACKUP_DIR"
safe_backup_dir || die "Unsafe backup path: $BACKUP_DIR"
[ ! -L "$CNI_BACKUP" ] && [ ! -L "$CNI_BACKUP.sha256" ] \
  || die "Backup targets must not be symbolic links."
cni_tmp="$(mktemp "$BACKUP_DIR/.cni.XXXXXX")"
docker exec "$NODE" cat "$CNI" > "$cni_tmp"
chmod 0600 "$cni_tmp"
mv -f -- "$cni_tmp" "$CNI_BACKUP"
sha256sum "$CNI_BACKUP" | awk '{print $1}' > "$CNI_BACKUP.sha256"

recreate_ns "$QID" runtime-check

# First remove the CNI configuration, then stop the CRI runtime. The visible
# .cka-disabled file is the recoverable incident artifact; the external backup
# is reserved for teardown safety.
docker exec "$NODE" sh -c "mv '$CNI' '$DISABLED'"
docker exec "$NODE" systemctl disable --now containerd

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: runtime-probe
  namespace: runtime-check
  labels:
    app: runtime-probe
spec:
  nodeName: cka-worker
  containers:
    - name: probe
      image: nginx:1.29
  restartPolicy: Always
EOF

[ "$(docker exec "$NODE" systemctl is-active containerd 2>/dev/null || true)" != active ] \
  || die "containerd did not stop."
docker exec "$NODE" sh -c "test ! -e '$CNI' && test -f '$DISABLED' && test ! -L '$DISABLED'" \
  || die "CNI failure was not established."

not_ready=0
for _ in $(seq 1 90); do
  if [ "$(kctx get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" != True ]; then
    not_ready=1
    break
  fi
  sleep 1
done
[ "$not_ready" -eq 1 ] || die "$NODE did not transition away from Ready."

if [ "$(kctx -n runtime-check get pod runtime-probe -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = True ]; then
  die "runtime-probe unexpectedly became Ready."
fi

SETUP_OK=1
info "$NODE has an inactive containerd service and a disabled CNI config."
