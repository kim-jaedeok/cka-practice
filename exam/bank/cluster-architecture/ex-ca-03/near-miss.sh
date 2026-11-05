#!/usr/bin/env bash
# Near-miss fixture: only the build error is fixed. The misspelled image name
# leaves the base tag in place.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

overlay="$CKA_WORK_DIR/ex-ca-03/overlays/staging"
sed -i 's#- ../base$#- ../../base#' "$overlay/kustomization.yaml"
kctx apply -k "$overlay" >/dev/null
wait_deploy kz-staging stg-catalog 180s
