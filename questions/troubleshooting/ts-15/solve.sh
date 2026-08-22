#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n service-chain patch service web-service --type=merge \
  -p '{"spec":{"selector":{"app":"web"}}}' >/dev/null

proxy_tmp="$(mktemp)"
trap 'rm -f -- "$proxy_tmp"' EXIT
kctx -n kube-system get configmap kube-proxy \
  -o jsonpath='{.data.config\.conf}' > "$proxy_tmp"
sed -i 's#/var/lib/kube-proxy/missing.conf#/var/lib/kube-proxy/kubeconfig.conf#' \
  "$proxy_tmp"
patch="$(python3 -c 'import json,sys; print(json.dumps({"data":{"config.conf":open(sys.argv[1]).read()}}))' "$proxy_tmp")"
kctx -n kube-system patch configmap kube-proxy --type=merge -p "$patch" >/dev/null

docker exec cka-worker2 sh -c '
  test -f /etc/cni/net.d/10-calico.conflist.cka-disabled
  mv -f /etc/cni/net.d/10-calico.conflist.cka-disabled \
    /etc/cni/net.d/10-calico.conflist
'

bad_proxy="$(kctx -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].metadata.name}')"
kctx -n kube-system delete pod "$bad_proxy" --wait=true --timeout=60s >/dev/null
kctx -n kube-system rollout status daemonset/kube-proxy --timeout=120s >/dev/null
kctx -n service-chain rollout status deployment/cni-probe --timeout=120s >/dev/null

for _ in $(seq 1 30); do
  if kctx -n service-chain exec service-client -- \
      wget -qO- -T 3 http://web-service 2>/dev/null | grep -qx 'service-chain-ok'; then
    exit 0
  fi
  sleep 2
done
exit 1
