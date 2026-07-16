#!/usr/bin/env bash
# 이 문제가 설치한 CRD를 제거한다
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
kctx delete crd backups.stable.example.com --ignore-not-found >/dev/null 2>&1 || true
