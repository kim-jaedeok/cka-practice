#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

cleanup_question ex-ca-01
kctx delete crd backuppolicies.dataprotection.example.org --ignore-not-found \
  --wait=true --timeout=90s >/dev/null
