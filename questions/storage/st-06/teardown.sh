#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/csi.sh"

csi_require_disposable_cell st-06 csi-cell

if ! cluster_ready; then
  exit 0
fi

kctx delete namespace csi-lab --ignore-not-found --wait=true \
  --timeout=120s >/dev/null 2>&1 || true
kctx delete storageclass csi-hostpath-lab --ignore-not-found >/dev/null 2>&1 || true

# Give the external provisioner a bounded opportunity to honor Delete reclaim.
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  if ! kctx get pv -o json 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
raise SystemExit(0 if not any(
    p.get("spec", {}).get("storageClassName") == "csi-hostpath-lab"
    for p in items
) else 1)
'; then
    sleep 2
    continue
  fi
  break
done

kctx delete namespace csi-hostpath --ignore-not-found --wait=true \
  --timeout=120s >/dev/null 2>&1 || true
kctx delete csidriver hostpath.csi.k8s.io --ignore-not-found >/dev/null 2>&1 || true
kctx delete clusterrolebinding csi-hostpathplugin-cka \
  --ignore-not-found >/dev/null 2>&1 || true
kctx delete clusterrole csi-hostpathplugin-cka --ignore-not-found >/dev/null 2>&1 || true
kctx delete pv -l "$CKA_LABEL_KEY=st-06" --ignore-not-found >/dev/null 2>&1 || true

workdir_clear st-06
