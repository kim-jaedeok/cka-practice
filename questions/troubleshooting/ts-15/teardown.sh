#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-15
CNI_NODE=cka-worker2
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
PROXY_BACKUP="$BACKUP_DIR/kube-proxy-config.conf"
CNI_BACKUP="$BACKUP_DIR/10-calico.conflist"
failed=0

[ "$BACKUP_DIR" = "$CKA_STATE_DIR/backup/$QID" ] \
  && [ ! -L "$CKA_STATE_DIR" ] \
  && [ ! -L "$CKA_STATE_DIR/backup" ] \
  && [ ! -L "$BACKUP_DIR" ] || exit 1

# Idempotent no-op path for a lab that has never established an incident.
if [ ! -e "$PROXY_BACKUP" ] && [ ! -e "$PROXY_BACKUP.sha256" ] \
    && [ ! -e "$CNI_BACKUP" ] && [ ! -e "$CNI_BACKUP.sha256" ]; then
  docker exec -i "$CNI_NODE" sh -ceu '
    test -f /etc/cni/net.d/10-calico.conflist
    test ! -L /etc/cni/net.d/10-calico.conflist
    test ! -e /etc/cni/net.d/10-calico.conflist.cka-disabled
  ' >/dev/null 2>&1 || exit 1
  kctx -n kube-system get configmap kube-proxy \
    -o jsonpath='{.data.config\.conf}' 2>/dev/null \
    | grep -q '^  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf$' || exit 1
  kctx -n kube-system rollout status daemonset/kube-proxy --timeout=30s \
    >/dev/null 2>&1 || exit 1
  kctx delete namespace service-chain --ignore-not-found --wait=true --timeout=90s \
    >/dev/null 2>&1 || exit 1
  exit 0
fi

backup_valid() { # backup_valid <file>
  local file="$1" expected actual
  [ -f "$file" ] && [ ! -L "$file" ] && [ -f "$file.sha256" ] && [ ! -L "$file.sha256" ] \
    || return 1
  read -r expected < "$file.sha256"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

if backup_valid "$CNI_BACKUP"; then
  docker exec -i "$CNI_NODE" sh -ceu '
    dir=/etc/cni/net.d
    target=$dir/10-calico.conflist
    disabled=$dir/10-calico.conflist.cka-disabled
    tmp=/tmp/cka-practice-ts-15-calico.conflist.restore
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

if backup_valid "$PROXY_BACKUP"; then
  patch="$(python3 -c 'import json,sys; print(json.dumps({"data":{"config.conf":open(sys.argv[1]).read()}}))' "$PROXY_BACKUP")" \
    || failed=1
  if [ -n "${patch:-}" ]; then
    kctx -n kube-system patch configmap kube-proxy --type=merge -p "$patch" \
      >/dev/null 2>&1 || failed=1
  fi
else
  failed=1
fi

# Recreate only the deliberately replaced worker Pod when it is still broken;
# healthy nodes are left untouched.
proxy_pod="$(kctx -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].metadata.name}' \
  2>/dev/null || true)"
proxy_ready="$(kctx -n kube-system get pod "$proxy_pod" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null || true)"
if [ -n "$proxy_pod" ] && [ "$proxy_ready" != True ]; then
  kctx -n kube-system delete pod "$proxy_pod" --wait=true --timeout=60s \
    >/dev/null 2>&1 || failed=1
fi

kctx -n kube-system rollout status daemonset/kube-proxy --timeout=120s \
  >/dev/null 2>&1 || failed=1
kctx delete namespace service-chain --ignore-not-found --wait=true --timeout=90s \
  >/dev/null 2>&1 || failed=1
exit "$failed"
