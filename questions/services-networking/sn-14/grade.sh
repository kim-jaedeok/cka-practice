#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-14

sn14_workload_fingerprint() {
  {
    kctx -n edge get deploy echo -o json 2>/dev/null || return 1
    kctx -n edge get configmap echo-conf -o json 2>/dev/null || return 1
  } | python3 -c '
import hashlib, json, sys
decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; parts = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    value, pos = decoder.raw_decode(text, pos)
    parts.append(value["metadata"]["uid"] + json.dumps(
        value.get("spec", value.get("data")), sort_keys=True, separators=(",", ":")))
print(hashlib.sha256("|".join(parts).encode()).hexdigest())
'
}

sn14_workload_unchanged() {
  local path="$CKA_STATE_DIR/question-data/sn-14/workload-fingerprint" expected current
  [ -s "$path" ] \
    || { grade_invalid "sn-14 baseline workload fingerprint missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(sn14_workload_fingerprint)" || return 1
  [ -n "$expected" ] && [ "$current" = "$expected" ] && deploy_ready edge echo 1
}

# The grader runs on the lab host, which is outside the cluster. The address
# the host uses toward cka-worker is the client IP the application must report.
sn14_source_ip_preserved() {
  local node_ip client_ip seen attempt
  node_ip="$(_jp_get node cka-worker - \
    '{.status.addresses[?(@.type=="InternalIP")].address}')" || return 1
  [[ "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  client_ip="$(ip -4 route get "$node_ip" 2>/dev/null \
    | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  [ -n "$client_ip" ] || {
    grade_invalid "sn-14 could not determine the host address toward cka-worker" || true
    return 2
  }
  # kube-proxy applies Service changes asynchronously.
  for attempt in 1 2 3 4 5; do
    seen="$(curl -s -m 3 "http://$node_ip:30880" 2>/dev/null | tr -d '[:space:]')"
    [ "$seen" = "$client_ip" ] && return 0
    sleep 1
  done
  return 1
}

criterion 2 "echo-svc uses externalTrafficPolicy Local" \
  "jp_eq svc echo-svc edge '{.spec.externalTrafficPolicy}' Local"

criterion 1 "echo-svc is still NodePort 30880 for app=echo" \
  "jp_eq svc echo-svc edge '{.spec.type}' NodePort && \
   jp_eq svc echo-svc edge '{.spec.selector.app}' echo && \
   jp_relation_has svc echo-svc edge \
     '{range .spec.ports[*]}{.port}{\"|\"}{.nodePort}{\"\\n\"}{end}' '80|30880'"

criterion 1 "Deployment and ConfigMap are unchanged and Ready" \
  "sn14_workload_unchanged"

criterion 2 "실측: 클러스터 밖 요청의 client IP가 그대로 보임" \
  "sn14_source_ip_preserved"

grade_finish
