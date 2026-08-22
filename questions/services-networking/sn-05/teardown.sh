#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/controllers.sh"
controller_require_disposable_cell sn-05 gateway-cell
kctx delete namespace traffic cka-controller-system \
  --ignore-not-found --wait=false >/dev/null 2>&1 || true
controller_cell_cleanup sn-05 gateway-cell >/dev/null 2>&1 || true
