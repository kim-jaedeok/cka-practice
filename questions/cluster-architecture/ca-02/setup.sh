#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-02
require_cluster
cleanup_question "$QID"
# 사용자가 만드는 cluster-scoped 리소스를 이름으로 정리
kctx delete clusterrole node-viewer --ignore-not-found >/dev/null 2>&1 || true
kctx delete clusterrolebinding node-viewer-binding --ignore-not-found >/dev/null 2>&1 || true
# dev-team ns가 없으면 생성 (ca-01과 공유하되 독립 동작 보장)
kctx get ns dev-team >/dev/null 2>&1 || recreate_ns "$QID" dev-team
kctx -n dev-team delete sa node-inspector --ignore-not-found >/dev/null 2>&1 || true
kctx -n dev-team create serviceaccount node-inspector >/dev/null
