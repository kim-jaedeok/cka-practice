#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=st-02
require_cluster
cleanup_question "$QID"
kctx delete storageclass fast-storage --ignore-not-found >/dev/null 2>&1 || true
recreate_ns "$QID" project-beta
