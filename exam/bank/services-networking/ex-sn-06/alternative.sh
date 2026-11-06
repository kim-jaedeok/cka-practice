#!/usr/bin/env bash
# Alternative fixture: convert the existing Service in place with one patch
# (type, externalName, and removal of selector and cluster IPs) instead of
# deleting and recreating it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n shop-frontend patch svc payments --type=merge -p '{"spec":{
  "type":"ExternalName",
  "externalName":"payments-api.payments-core.svc.cluster.local.",
  "selector":null,"clusterIP":null,"clusterIPs":null}}' >/dev/null
kctx -n shop-frontend delete deploy payments-legacy --wait=true >/dev/null
kctx -n shop-frontend wait --for=delete pod -l app=payments-legacy --timeout=60s >/dev/null 2>&1 || true
