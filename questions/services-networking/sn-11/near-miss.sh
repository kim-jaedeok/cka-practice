#!/usr/bin/env bash
# Near-miss fixture: eth0 is the node's own uplink, but cross-node Pod traffic
# leaves through the CNI overlay interface instead.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/sn-11"
printf 'eth0\n' > "$CKA_WORK_DIR/sn-11/egress-interface.txt"
