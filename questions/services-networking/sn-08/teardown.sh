#!/usr/bin/env bash
# CoreDNS Corefile을 원본으로 복원한다
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

BACKUP="$CKA_STATE_DIR/backup/coredns-corefile.txt"
[ -f "$BACKUP" ] || exit 0

python3 - "$BACKUP" <<'PYEOF' > /tmp/coredns-restore.json
import json, sys
corefile = open(sys.argv[1]).read()
print(json.dumps({"data": {"Corefile": corefile}}))
PYEOF
kctx -n kube-system patch cm coredns --type=merge --patch-file=/tmp/coredns-restore.json >/dev/null
rm -f /tmp/coredns-restore.json
kctx -n kube-system rollout restart deploy/coredns >/dev/null
kctx -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 || true
