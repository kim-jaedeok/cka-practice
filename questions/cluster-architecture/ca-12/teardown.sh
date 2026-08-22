#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"
CKA_ENABLE_KUBEADM_CELLS=1 cell_cleanup ca-12 kubeadm-bootstrap
