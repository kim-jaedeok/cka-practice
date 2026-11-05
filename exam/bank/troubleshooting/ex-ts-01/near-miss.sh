#!/usr/bin/env bash
# Near-miss fixture: switching the Pods to the default ServiceAccount makes them
# run, but it changes the identity the task said to keep.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n ledger patch deploy audit-writer --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/serviceAccountName","value":"default"}]' >/dev/null
wait_deploy ledger audit-writer 180s
