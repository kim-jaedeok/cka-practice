#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"

if cell_activate ca-06 kubeadm-upgrade >/dev/null 2>&1; then
  kctx uncordon "$CKA_CELL_NODE_WORKER2" >/dev/null 2>&1 || true
  kctx delete namespace node-upgrade --ignore-not-found --wait=false \
    >/dev/null 2>&1 || true
fi
