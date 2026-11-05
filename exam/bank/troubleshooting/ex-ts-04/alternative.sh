#!/usr/bin/env bash
# Alternative fixture: give the canary Pods an app label of their own. The
# Service and shop-web stay unchanged, and the canary keeps 1 Ready replica.
# The selector is immutable, so the canary Deployment is recreated.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n storefront get deploy shop-canary -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["metadata"] = {"name": d["metadata"]["name"], "namespace": d["metadata"]["namespace"]}
d.pop("status", None)
d["spec"]["selector"]["matchLabels"]["app"] = "shop-canary"
d["spec"]["template"]["metadata"]["labels"]["app"] = "shop-canary"
print(json.dumps(d))
' > "${TMPDIR:-/tmp}/ex-ts-04-canary.json"
kctx -n storefront delete deploy shop-canary --wait=true >/dev/null
kctx apply -f "${TMPDIR:-/tmp}/ex-ts-04-canary.json" >/dev/null
rm -f "${TMPDIR:-/tmp}/ex-ts-04-canary.json"
wait_deploy storefront shop-canary 180s
kctx -n storefront wait --for=delete pod -l app=shop,track=canary --timeout=90s >/dev/null 2>&1 || true
sleep 3
