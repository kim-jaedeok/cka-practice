#!/usr/bin/env bash
# Deliberately incomplete: CRI is back, but the CNI config remains disabled.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec cka-worker systemctl enable --now containerd
