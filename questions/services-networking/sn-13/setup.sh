#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-13
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" training
workdir_reset "$QID"
