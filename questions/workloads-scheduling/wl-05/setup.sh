#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-05
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" scheduling

# 문제 환경: cka-worker에 라벨, cka-worker2에 taint
kctx label node cka-worker disktype=ssd --overwrite >/dev/null
kctx taint node cka-worker2 env=prod:NoSchedule --overwrite >/dev/null
