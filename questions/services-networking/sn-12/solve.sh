#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/sn-12"
docker exec cka-worker sh -c 'cat /etc/cni/net.d/10-calico.conflist' | python3 -c '
import json, sys
doc = json.load(sys.stdin)
print(next(p["ipam"]["type"] for p in doc["plugins"] if p.get("ipam")))
' > "$CKA_WORK_DIR/sn-12/ipam.txt"
