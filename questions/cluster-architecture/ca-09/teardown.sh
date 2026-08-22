#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/controllers.sh"
controller_require_disposable_cell ca-09 operator-cell
kctx delete namespace operators cka-controller-system \
  --ignore-not-found --wait=false >/dev/null 2>&1 || true
controller_cell_cleanup ca-09 operator-cell >/dev/null 2>&1 || true
