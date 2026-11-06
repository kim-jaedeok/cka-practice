#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-st-04
QDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
require_cluster
[ "$(kctx get storageclass standard -o jsonpath='{.provisioner}')" = rancher.io/local-path ] \
  || die "ex-st-04: StorageClass standard가 local-path provisioner가 아닙니다."

bash "$QDIR/teardown.sh" >/dev/null 2>&1 || true
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" edge-data
