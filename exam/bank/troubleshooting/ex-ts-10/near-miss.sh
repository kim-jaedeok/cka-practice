#!/usr/bin/env bash
# Near-miss fixture: the namespace is forced out through the finalize
# subresource. It disappears, but the objects that blocked it stay in storage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx get namespace tenant-old -o json \
  | python3 -c 'import json,sys; ns=json.load(sys.stdin); ns["spec"]["finalizers"]=[]; print(json.dumps(ns))' \
  > "${TMPDIR:-/tmp}/ex-ts-10-ns.json"
kctx replace --raw /api/v1/namespaces/tenant-old/finalize -f "${TMPDIR:-/tmp}/ex-ts-10-ns.json" >/dev/null
rm -f "${TMPDIR:-/tmp}/ex-ts-10-ns.json"
kctx wait --for=delete namespace/tenant-old --timeout=60s >/dev/null
