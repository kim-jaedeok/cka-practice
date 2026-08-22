#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

QID=ts-13
ACTIVE_MARKER="$CKA_STATE_DIR/backup/$QID/active"
grade_init ts-13

# API unavailability is the deliberately created candidate state for this one
# individual-only lab. Convert only the grader-owned active incident to an
# ordinary failed attempt; unrelated API outages remain INVALID.
if [ "$_G_INVALID" -ne 0 ] && [ -f "$ACTIVE_MARKER" ] \
    && [ ! -L "$ACTIVE_MARKER" ] \
    && [ "$(cat "$ACTIVE_MARKER" 2>/dev/null)" = "$QID" ]; then
  _G_INVALID=0
  _G_INVALID_REASONS=()
fi

ts13_control_plane_ready() {
  local attempt etcd_ready api_ready
  [ "$(kctx --request-timeout=3s get --raw=/readyz 2>/dev/null || true)" = ok ] \
    || return 1
  # /readyz can turn green just before the restarted API server's authorization
  # caches accept ordinary admin requests. Keep the post-recovery checks bounded
  # but allow that short convergence window.
  for attempt in $(seq 1 30); do
    etcd_ready="$(kctx --request-timeout=2s -n kube-system get pod etcd-cka-control-plane \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    api_ready="$(kctx --request-timeout=2s -n kube-system get pod kube-apiserver-cka-control-plane \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "$etcd_ready" = True ] && [ "$api_ready" = True ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ts13_etcd_healthy() {
  node_exec cka-control-plane '
    ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
      endpoint health
  '
}

criterion 2 "etcd secure loopback client listener restored" \
  "node_exec cka-control-plane 'grep -q -- \"--listen-client-urls=https://127.0.0.1:2379,\" /etc/kubernetes/manifests/etcd.yaml'"

criterion 2 "kube-apiserver points to local etcd on 2379" \
  "node_exec cka-control-plane 'grep -qx -- \"    - --etcd-servers=https://127.0.0.1:2379\" /etc/kubernetes/manifests/kube-apiserver.yaml'"

criterion 2 "etcd endpoint health succeeds with TLS" \
  "ts13_etcd_healthy"

criterion 2 "etcd and kube-apiserver static Pods are Ready" \
  "ts13_control_plane_ready"

grade_finish
