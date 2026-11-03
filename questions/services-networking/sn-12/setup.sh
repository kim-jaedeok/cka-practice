#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-12
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"

# Record the node's CNI configuration so grading can prove it was not edited.
mkdir -p "$CKA_STATE_DIR/question-data/$QID"
docker exec cka-worker sh -c 'cat /etc/cni/net.d/*.conflist' | sha256sum | awk '{print $1}' \
  > "$CKA_STATE_DIR/question-data/$QID/cni-conf-sha256"
