#!/usr/bin/env bash
# Near-miss fixture: host-local is a common IPAM plugin and its binary exists in
# /opt/cni/bin, but this cluster's configuration does not use it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/sn-12"
printf 'host-local\n' > "$CKA_WORK_DIR/sn-12/ipam.txt"
