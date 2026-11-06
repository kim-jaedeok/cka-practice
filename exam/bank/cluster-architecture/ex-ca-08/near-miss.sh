#!/usr/bin/env bash
# Near-miss fixture: the token and the join command are right, but the token
# keeps the default lifetime of 24 hours.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ex-ca-08"
docker exec "$(cka_cp_node)" kubeadm token create \
  --description "rack-b expansion" --print-join-command \
  > "$CKA_WORK_DIR/ex-ca-08/join-worker.sh"
