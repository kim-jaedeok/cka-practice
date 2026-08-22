#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/csi.sh"

QID=st-06
ASSET_DEST="$CKA_WORK_DIR/$QID/csi-hostpath-driver.yaml"

csi_require_disposable_cell "$QID" csi-cell
require_cluster_readonly

# A fresh cell should already be empty. These exact, question-owned names make
# reset deterministic without touching unrelated cluster-scoped resources.
kctx delete namespace csi-lab csi-hostpath --ignore-not-found --wait=true \
  --timeout=120s >/dev/null 2>&1 || true
kctx delete storageclass csi-hostpath-lab --ignore-not-found >/dev/null 2>&1 || true
kctx delete csidriver hostpath.csi.k8s.io --ignore-not-found >/dev/null 2>&1 || true
kctx delete clusterrolebinding csi-hostpathplugin-cka \
  --ignore-not-found >/dev/null 2>&1 || true
kctx delete clusterrole csi-hostpathplugin-cka --ignore-not-found >/dev/null 2>&1 || true

mapfile -t workers < <(kctx get nodes \
  -l '!node-role.kubernetes.io/control-plane' -o name)
[ "${#workers[@]}" -eq 1 ] || die "CSI cell must contain exactly one worker"
kctx label nodes --all cka-practice/csi-node- >/dev/null 2>&1 || true
kctx label "${workers[0]}" cka-practice/csi-node=true --overwrite >/dev/null

kctx create namespace csi-lab >/dev/null
kctx label namespace csi-lab "$CKA_LABEL_KEY=$QID" --overwrite >/dev/null

workdir_reset "$QID"
csi_publish_candidate_asset "$ASSET_DEST"

! kctx get csidriver hostpath.csi.k8s.io >/dev/null 2>&1 \
  || die "CSI driver baseline was not clean"
! kctx get storageclass csi-hostpath-lab >/dev/null 2>&1 \
  || die "CSI StorageClass baseline was not clean"
