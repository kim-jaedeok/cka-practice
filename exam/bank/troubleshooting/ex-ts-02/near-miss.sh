#!/usr/bin/env bash
# Near-miss fixture: a literal DB_PASSWORD makes the Pods start, but the value
# no longer comes from the Secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n billing patch deploy invoice-api --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/1","value":{"name":"DB_PASSWORD","value":"Tr4nsact10n-Ledger"}}]' >/dev/null
wait_deploy billing invoice-api 180s
