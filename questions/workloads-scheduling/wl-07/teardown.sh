#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mapfile -t nodes < <(kctx get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
for node in "${nodes[@]}"; do
  kctx label node "$node" cka-practice/wl07- >/dev/null 2>&1 || true
done
