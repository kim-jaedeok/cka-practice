#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

# Deleting the namespace deletes the claim. The provisioner then deletes the
# volume (reclaim policy Delete). Wait for that before removing the class.
cleanup_question ex-st-04
for _ in $(seq 1 30); do
  left="$(kctx get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="edge-local")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [ -z "$left" ] && break
  sleep 2
done
for pv in $(kctx get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="edge-local")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  kctx patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null 2>&1 || true
  kctx delete pv "$pv" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
kctx delete storageclass edge-local --ignore-not-found >/dev/null
