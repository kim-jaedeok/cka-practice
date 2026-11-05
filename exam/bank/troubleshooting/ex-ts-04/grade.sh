#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-04

exts04_shop_web_unchanged() {
  local path="$CKA_STATE_DIR/question-data/ex-ts-04/shop-web-fingerprint" expected current
  [ -s "$path" ] \
    || { grade_invalid "ex-ts-04 baseline Deployment fingerprint missing" || true; return 2; }
  expected="$(tr -d '\r\n' < "$path")"
  current="$(kctx -n storefront get deploy shop-web -o json 2>/dev/null | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(json.dumps(
    [obj["spec"]["replicas"], obj["spec"]["selector"], obj["spec"]["template"]],
    sort_keys=True).encode()).hexdigest())
')" || return 1
  [ "$current" = "$expected" ]
}

# The ready endpoints of shop-svc are exactly the Running shop-web Pod IPs.
exts04_endpoints_only_web() {
  local web endpoints
  web="$(kctx -n storefront get pods -l app=shop,track=stable \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null | sort -u)" || return 1
  endpoints="$(kctx -n storefront get endpointslices -l kubernetes.io/service-name=shop-svc \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}' \
    2>/dev/null | sort -u)" || return 1
  [ -n "$web" ] && [ "$(printf '%s\n' "$web" | grep -c .)" -eq 2 ] && [ "$web" = "$endpoints" ]
}

# Eight consecutive requests through the Service are all served by shop-web.
exts04_all_requests_stable() {
  _grader_client_require || return $?
  _dns_baseline_grader || return $?
  kctx -n cka-system exec deploy/grader-client -- sh -c '
    i=0
    while [ "$i" -lt 8 ]; do
      body="$(wget -q -O - -T 4 http://shop-svc.storefront.svc.cluster.local/ 2>/dev/null)" || exit 1
      [ "$body" = "shop-web stable" ] || exit 1
      i=$((i + 1))
    done
  ' >/dev/null 2>&1
}

_python3_require || true

criterion 3 "shop-svc endpoints are exactly the shop-web Pods" \
  "exts04_endpoints_only_web"

criterion 1 "Deployment shop-web is unchanged and has 2 Ready replicas" \
  "exts04_shop_web_unchanged && deploy_ready storefront shop-web 2"

criterion 1 "Deployment shop-canary still has 1 Ready replica" \
  "deploy_ready storefront shop-canary 1"

criterion 2 "실측: 8 requests to shop-svc are all answered by shop-web" \
  "exts04_all_requests_stable"

grade_finish
