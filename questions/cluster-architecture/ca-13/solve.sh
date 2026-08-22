#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/cell.sh"

cell_activate ca-13 operator-cell

kctx apply --server-side --force-conflicts \
  -f "$CKA_WORK_DIR/ca-13/cert-manager-v1.21.1.yaml" >/dev/null
kctx -n cert-manager wait --for=condition=Available \
  deployment/cert-manager deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook --timeout=180s >/dev/null
kctx -n operator-verify wait --for=condition=Ready \
  certificate/install-proof --timeout=120s >/dev/null
