#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ca-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" dev-team
kctx -n dev-team create serviceaccount app-reader >/dev/null
