#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-03
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" kz-staging

# The overlay has two faults: a wrong base path (build error) and a misspelled
# image name in the images transformer (silently keeps the base tag).
cp -r "$(dirname "${BASH_SOURCE[0]}")/files/." "$CKA_WORK_DIR/$QID/"
