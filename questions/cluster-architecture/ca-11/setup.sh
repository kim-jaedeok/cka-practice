#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"

[ "${CKA_ENABLE_KUBEADM_CELLS:-0}" = 1 ] \
  || die "ca-11 requires full mode (CKA_ENABLE_KUBEADM_CELLS=1)."
cell_prepare ca-11 kubeadm-ha
