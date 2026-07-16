#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
# (원인인 forwardx 오타를 forward로 되돌린다)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/Corefile.fix
sed -i 's/^\([[:space:]]*\)forwardx /\1forward /' /tmp/Corefile.fix

python3 - /tmp/Corefile.fix <<'PYEOF' > /tmp/coredns-fix.json
import json, sys
corefile = open(sys.argv[1]).read()
print(json.dumps({"data": {"Corefile": corefile}}))
PYEOF
kctx -n kube-system patch cm coredns --type=merge --patch-file=/tmp/coredns-fix.json
rm -f /tmp/Corefile.fix /tmp/coredns-fix.json

kctx -n kube-system rollout restart deploy/coredns
kctx -n kube-system rollout status deploy/coredns --timeout=180s
