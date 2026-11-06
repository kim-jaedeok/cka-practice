#!/usr/bin/env bash
# Near-miss fixture: the ExternalName uses the short Service name. The CNAME
# target "payments-api" does not resolve, so clients get no answer.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n shop-frontend delete svc payments --wait=true >/dev/null
kctx -n shop-frontend create service externalname payments --external-name payments-api >/dev/null
kctx -n shop-frontend delete deploy payments-legacy --wait=true >/dev/null
kctx -n shop-frontend wait --for=delete pod -l app=payments-legacy --timeout=60s >/dev/null 2>&1 || true
