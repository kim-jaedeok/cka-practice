#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

QID=ts-15
BACKUP_DIR="$CKA_STATE_DIR/backup/$QID"
grade_init ts-15

ts15_hash_matches() { # ts15_hash_matches <node|local> <target> <sha-file>
  local scope="$1" target="$2" sha_file="$3" expected actual checksum_line
  [ -f "$sha_file" ] || return 1
  read -r expected < "$sha_file"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  if [ "$scope" = local ]; then
    actual="$(kctx -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' \
      | sha256sum | awk '{print $1}')" || return 1
  else
    checksum_line="$(node_exec_out "$scope" "sha256sum '$target' 2>/dev/null")" || return 1
    actual="${checksum_line%% *}"
  fi
  [ "$actual" = "$expected" ]
}

ts15_two_ready_endpoints() {
  _python3_require || return $?
  kctx -n service-chain get endpointslice \
    -l kubernetes.io/service-name=web-service -o json \
    | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items") or []
ready = [
    endpoint
    for item in items
    for endpoint in (item.get("endpoints") or [])
    if (endpoint.get("conditions") or {}).get("ready") is True
]
raise SystemExit(0 if len(ready) == 2 else 1)
'
}

ts15_kube_proxy_ready() {
  local status generation observed desired ready available
  status="$(kctx -n kube-system get daemonset kube-proxy \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.desiredNumberScheduled}{"|"}{.status.numberReady}{"|"}{.status.numberAvailable}' \
    2>/dev/null)" || return 1
  IFS='|' read -r generation observed desired ready available <<< "$status"
  [ "$generation" = "$observed" ] && [ "$desired" = 3 ] \
    && [ "$ready" = 3 ] && [ "$available" = 3 ]
}

criterion 2 "Service selects app=web and has two ready EndpointSlice backends" \
  "jp_eq service web-service service-chain '{.spec.selector.app}' web && \
   jp_eq service web-service service-chain '{.spec.ports[0].port}' 80 && \
   jp_eq service web-service service-chain '{.spec.ports[0].targetPort}' 80 && \
   ts15_two_ready_endpoints"

criterion 1 "kube-proxy ConfigMap is restored exactly" \
  "ts15_hash_matches local - '$BACKUP_DIR/kube-proxy-config.conf.sha256'"

criterion 1 "kube-proxy DaemonSet is fully Ready on all three nodes" \
  "ts15_kube_proxy_ready"

criterion 1 "worker2 original CNI config is restored" \
  "ts15_hash_matches cka-worker2 /etc/cni/net.d/10-calico.conflist '$BACKUP_DIR/10-calico.conflist.sha256' && node_exec cka-worker2 'test ! -e /etc/cni/net.d/10-calico.conflist.cka-disabled'"

criterion 1 "cni-probe Deployment is Ready on worker2" \
  "deploy_ready service-chain cni-probe 1"

criterion 2 "live Service request returns the expected response" \
  "[ \"\$(kctx -n service-chain exec service-client -- wget -qO- -T 3 http://web-service 2>/dev/null)\" = service-chain-ok ]"

grade_finish
