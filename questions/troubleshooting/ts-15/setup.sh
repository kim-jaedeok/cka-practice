#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=ts-15
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CNI_NODE=cka-worker2
CNI=/etc/cni/net.d/10-calico.conflist
CNI_DISABLED=/etc/cni/net.d/10-calico.conflist.cka-disabled
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
PROXY_BACKUP="$BACKUP_DIR/kube-proxy-config.conf"
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

if [ -f "$PROXY_BACKUP.sha256" ] || [ -f "$CNI_BACKUP.sha256" ]; then
  bash "$HERE/teardown.sh"
fi
require_cluster
cleanup_question "$QID"
kctx wait --for=condition=Ready node --all --timeout=15s >/dev/null \
  || die "All nodes must be Ready before starting this lab."
kctx -n kube-system rollout status daemonset/kube-proxy --timeout=30s >/dev/null \
  || die "kube-proxy baseline is not fully Ready."
docker exec "$CNI_NODE" sh -c "test -d /etc/cni/net.d && test ! -L /etc/cni/net.d && test -f '$CNI' && test ! -L '$CNI' && test ! -e '$CNI_DISABLED'" \
  || die "CNI baseline is unsafe or already modified on $CNI_NODE."

mkdir -p "$BACKUP_DIR"
safe_backup_dir || die "Unsafe backup path: $BACKUP_DIR"
[ ! -L "$PROXY_BACKUP" ] && [ ! -L "$PROXY_BACKUP.sha256" ] \
  && [ ! -L "$CNI_BACKUP" ] && [ ! -L "$CNI_BACKUP.sha256" ] \
  || die "Backup targets must not be symbolic links."
proxy_tmp="$(mktemp "$BACKUP_DIR/.proxy.XXXXXX")"
cni_tmp="$(mktemp "$BACKUP_DIR/.cni.XXXXXX")"
kctx -n kube-system get configmap kube-proxy \
  -o jsonpath='{.data.config\.conf}' > "$proxy_tmp"
grep -q '^  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf$' "$proxy_tmp" \
  || die "kube-proxy baseline kubeconfig path is unexpected."
docker exec "$CNI_NODE" cat "$CNI" > "$cni_tmp"
chmod 0600 "$proxy_tmp" "$cni_tmp"
mv -f -- "$proxy_tmp" "$PROXY_BACKUP"
mv -f -- "$cni_tmp" "$CNI_BACKUP"
sha256sum "$PROXY_BACKUP" | awk '{print $1}' > "$PROXY_BACKUP.sha256"
sha256sum "$CNI_BACKUP" | awk '{print $1}' > "$CNI_BACKUP.sha256"

recreate_ns "$QID" service-chain
kctx apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-content
  namespace: service-chain
data:
  index.html: "service-chain-ok\n"
---
apiVersion: v1
kind: Pod
metadata:
  name: web-worker
  namespace: service-chain
  labels: {app: web}
spec:
  nodeName: cka-worker
  containers:
    - name: nginx
      image: nginx:1.29
      volumeMounts:
        - name: content
          mountPath: /usr/share/nginx/html
  volumes:
    - name: content
      configMap: {name: web-content}
---
apiVersion: v1
kind: Pod
metadata:
  name: web-worker2
  namespace: service-chain
  labels: {app: web}
spec:
  nodeName: cka-worker2
  containers:
    - name: nginx
      image: nginx:1.29
      volumeMounts:
        - name: content
          mountPath: /usr/share/nginx/html
  volumes:
    - name: content
      configMap: {name: web-content}
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: service-chain
spec:
  selector: {app: web}
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: service-client
  namespace: service-chain
spec:
  nodeName: cka-control-plane
  containers:
    - name: client
      image: busybox:1.36
      command: [sh, -c, "sleep 7200"]
EOF

wait_pod service-chain web-worker 120s
wait_pod service-chain web-worker2 120s
wait_pod service-chain service-client 120s
kctx -n service-chain exec service-client -- \
  wget -qO- -T 3 http://web-service | grep -qx 'service-chain-ok' \
  || die "Service baseline data path is not healthy."

# Layer 1: remove all selector-derived backends.
kctx -n service-chain patch service web-service --type=merge \
  -p '{"spec":{"selector":{"app":"web-broken"}}}' >/dev/null

# Layer 2: point kube-proxy at a missing kubeconfig and replace only the Pod on
# cka-worker. Existing healthy Pods retain the already loaded configuration.
bad_proxy="$(mktemp "$BACKUP_DIR/.bad-proxy.XXXXXX")"
sed 's#^  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf$#  kubeconfig: /var/lib/kube-proxy/missing.conf#' \
  "$PROXY_BACKUP" > "$bad_proxy"
bad_patch="$(python3 -c 'import json,sys; print(json.dumps({"data":{"config.conf":open(sys.argv[1]).read()}}))' "$bad_proxy")"
kctx -n kube-system patch configmap kube-proxy --type=merge -p "$bad_patch" >/dev/null
rm -f -- "$bad_proxy"

old_proxy="$(kctx -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].metadata.name}')"
old_uid="$(kctx -n kube-system get pod "$old_proxy" -o jsonpath='{.metadata.uid}')"
kctx -n kube-system delete pod "$old_proxy" --wait=true --timeout=60s >/dev/null

proxy_broken=0
for _ in $(seq 1 60); do
  new_proxy="$(kctx -n kube-system get pod -l k8s-app=kube-proxy \
    --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  new_uid="$(kctx -n kube-system get pod "$new_proxy" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  restart_count="$(kctx -n kube-system get pod "$new_proxy" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  ready="$(kctx -n kube-system get pod "$new_proxy" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] \
      && [[ "${restart_count:-}" =~ ^[1-9][0-9]*$ ]] && [ "$ready" != True ]; then
    proxy_broken=1
    break
  fi
  sleep 1
done
[ "$proxy_broken" -eq 1 ] || die "The kube-proxy failure was not established."

# Layer 3: retain the original as a visible incident artifact and make the
# recognized .conflist deterministically unusable before creating a sandbox.
docker exec "$CNI_NODE" sh -ceu "
  mv '$CNI' '$CNI_DISABLED'
  printf '%s\\n' '{\"cniVersion\":\"1.0.0\",\"name\":\"cka-broken\",\"plugins\":[]}' > '$CNI'
  chmod 0600 '$CNI'
"
sleep 3
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cni-probe
  namespace: service-chain
spec:
  replicas: 1
  selector:
    matchLabels: {app: cni-probe}
  template:
    metadata:
      labels: {app: cni-probe}
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker2
      containers:
        - name: probe
          image: nginx:1.29
EOF

sleep 15
if [ "$(kctx -n service-chain get deploy cni-probe -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" = 1 ]; then
  die "cni-probe unexpectedly became Ready."
fi
endpoints_removed=0
for _ in $(seq 1 30); do
  ready_endpoints="$(kctx -n service-chain get endpointslice \
    -l kubernetes.io/service-name=web-service -o json \
    | python3 -c 'import json,sys; print(sum(1 for s in (json.load(sys.stdin).get("items") or []) for e in (s.get("endpoints") or []) if (e.get("conditions") or {}).get("ready") is True))')"
  if [ "$ready_endpoints" -eq 0 ]; then
    endpoints_removed=1
    break
  fi
  sleep 1
done
[ "$endpoints_removed" -eq 1 ] || die "The broken Service still has ready endpoints."

SETUP_OK=1
info "Service selector, one kube-proxy Pod, and worker2 CNI are broken."
