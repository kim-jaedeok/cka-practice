#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-06
require_cluster
cleanup_question "$QID"

# 원본 Corefile 백업 (sn-08과 공유)
mkdir -p "$CKA_STATE_DIR/backup"
if [ ! -f "$CKA_STATE_DIR/backup/coredns-corefile.txt" ]; then
  kctx -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' \
    > "$CKA_STATE_DIR/backup/coredns-corefile.txt"
fi

# forward 플러그인 이름을 망가뜨려 CoreDNS를 CrashLoop으로 만든다
kctx -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/Corefile.ts06
sed -i 's/^\([[:space:]]*\)forward /\1forwardx /' /tmp/Corefile.ts06

python3 - /tmp/Corefile.ts06 <<'PYEOF' > /tmp/coredns-break.json
import json, sys
corefile = open(sys.argv[1]).read()
print(json.dumps({"data": {"Corefile": corefile}}))
PYEOF
kctx -n kube-system patch cm coredns --type=merge --patch-file=/tmp/coredns-break.json >/dev/null
rm -f /tmp/Corefile.ts06 /tmp/coredns-break.json

kctx -n kube-system rollout restart deploy/coredns >/dev/null
info "CoreDNS가 잘못된 설정으로 재시작됩니다. 잠시 후 CrashLoopBackOff 상태가 됩니다."
sleep 5
