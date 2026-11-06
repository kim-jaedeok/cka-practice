#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

docker exec "${CKA_CLUSTER_NAME}-worker2" rm -f /etc/kubernetes/manifests/edge-cache.yaml
cleanup_question ex-ts-06
question_state_clear ex-ts-06
