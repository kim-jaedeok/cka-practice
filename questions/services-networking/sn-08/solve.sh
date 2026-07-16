#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# Corefile의 서버 블록 첫 줄(".:53 {") 다음에 log 플러그인 삽입
kctx -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/Corefile
if ! grep -qE '^\s*log\s*$' /tmp/Corefile; then
  sed -i '0,/^\.:53 {/s//.:53 {\n    log/' /tmp/Corefile
fi

python3 - /tmp/Corefile <<'PYEOF' > /tmp/coredns-patch.json
import json, sys
corefile = open(sys.argv[1]).read()
print(json.dumps({"data": {"Corefile": corefile}}))
PYEOF
kctx -n kube-system patch cm coredns --type=merge --patch-file=/tmp/coredns-patch.json
rm -f /tmp/Corefile /tmp/coredns-patch.json

kctx -n kube-system rollout restart deploy/coredns
kctx -n kube-system rollout status deploy/coredns --timeout=120s

mkdir -p "$CKA_WORK_DIR/sn-08"
kctx -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' \
  > "$CKA_WORK_DIR/sn-08/dns-ip.txt"
