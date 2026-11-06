#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

docker exec "$(cka_cp_node)" rm -rf /var/lib/etcd-backup
cleanup_question ex-ca-05
question_state_clear ex-ca-05
