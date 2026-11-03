#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-17

ts17_legacy_unchanged() {
  local path="$CKA_STATE_DIR/question-data/ts-17/legacy-uid" expected
  [ -s "$path" ] \
    || { grade_invalid "ts-17 baseline legacy-agent UID missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  jp_eq pod legacy-agent node-agents '{.metadata.uid}' "$expected" \
    && pod_ready node-agents legacy-agent
}

ts17_exporter_placed() {
  pod_ready node-agents metrics-exporter \
    && jp_eq pod metrics-exporter node-agents '{.spec.nodeName}' cka-worker \
    && jp_eq pod metrics-exporter node-agents '{.spec.hostNetwork}' true
}

# Both agents share cka-worker's network namespace, so each must answer on the
# node's InternalIP at its own port.
ts17_node_ports_serve() {
  local ip
  ip="$(_jp_get node cka-worker - \
    '{.status.addresses[?(@.type=="InternalIP")].address}')" || return 1
  [ -n "$ip" ] || return 1
  http_body_contains "http://$ip:9181" exporter \
    && http_body_contains "http://$ip:9180" legacy
}

criterion 1 "legacy-agent is the original Pod and still Ready" \
  "ts17_legacy_unchanged"

criterion 2 "metrics-exporter is Ready on cka-worker with hostNetwork" \
  "ts17_exporter_placed"

criterion 1 "metrics-exporter declares container port 9181" \
  "jp_array_has pod metrics-exporter node-agents '{.spec.containers[*].ports[*].containerPort}' 9181"

criterion 2 "실측: node port 9181 serves exporter and 9180 still serves legacy" \
  "ts17_node_ports_serve"

grade_finish
