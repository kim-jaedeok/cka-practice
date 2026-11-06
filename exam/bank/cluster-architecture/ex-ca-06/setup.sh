#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-06
QDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
require_cluster
command -v helm >/dev/null 2>&1 || PATH="$HOME/.local/bin:$PATH"
command -v helm >/dev/null 2>&1 || die "helm이 설치되어 있지 않습니다. 'cka cluster up'을 다시 실행하세요."

cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" ops-dash

# Revision 1 works. Revision 2 was rolled out with an image tag that does not
# exist, so its new Pod never starts.
helm --kube-context "$CKA_CONTEXT" -n ops-dash install board \
  "$QDIR/files/chart-0.1.0/status-board" >/dev/null
wait_deploy ops-dash board || die "ex-ca-06 revision 1이 Ready가 아닙니다."
helm --kube-context "$CKA_CONTEXT" -n ops-dash upgrade board \
  "$QDIR/files/chart-0.1.0/status-board" --set image.tag=1.99-hotfix >/dev/null

# The candidate gets the new chart version and the production values only.
cp -r "$QDIR/files/work/." "$CKA_WORK_DIR/$QID/"
