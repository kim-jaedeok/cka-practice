#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-01
require_cluster
cleanup_question "$QID"
# The candidate creates the CRD. It is cluster-scoped and carries no question
# label, so remove any copy left by an earlier attempt by its exact name.
kctx delete crd backuppolicies.dataprotection.example.org --ignore-not-found \
  --wait=true --timeout=90s >/dev/null
recreate_ns "$QID" backup-ops
