#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-03

DATA=http://collector.telemetry.svc.cluster.local:8080/
ADMIN=http://collector.telemetry.svc.cluster.local:9090/

exsn03_policy() {
  jp_eq networkpolicy collector-access telemetry '{.spec.podSelector.matchLabels.app}' collector && \
  jp_array_has networkpolicy collector-access telemetry '{.spec.policyTypes[*]}' Ingress
}

criterion 1 "NetworkPolicy collector-access selects app=collector for Ingress" \
  "exsn03_policy"

criterion 2 "실측: edge-ingest/shipper reaches port 8080" \
  "http_ok_from edge-ingest shipper $DATA"

criterion 1 "실측: edge-ingest/shipper is blocked on port 9090" \
  "http_denied_from edge-ingest shipper $ADMIN"

criterion 2 "실측: telemetry/admin-shell reaches port 9090" \
  "http_ok_from telemetry admin-shell $ADMIN"

criterion 1 "실측: telemetry/admin-shell is blocked on port 8080" \
  "http_denied_from telemetry admin-shell $DATA"

criterion 1 "실측: telemetry/app-shell is blocked on both ports" \
  "http_denied_from telemetry app-shell $DATA && http_denied_from telemetry app-shell $ADMIN"

criterion 1 "실측: edge-other/shipper is blocked on port 8080" \
  "http_denied_from edge-other shipper $DATA"

grade_finish
