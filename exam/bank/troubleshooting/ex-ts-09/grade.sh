#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-09

EXTS09_DATA="$CKA_STATE_DIR/question-data/ex-ts-09"

exts09_cart_exec() { # <timeout-seconds> <command...>
  local limit="$1"
  shift
  deploy_ready checkout cart 1 || return 1
  timeout "$limit" kubectl --context "$CKA_CONTEXT" -n checkout exec deploy/cart -c cart -- "$@"
}

exts09_default_deny_unchanged() {
  kctx -n checkout get networkpolicy default-deny-egress -o json 2>/dev/null | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]
ok = (spec.get("podSelector") in ({}, None)
      and spec.get("policyTypes") == ["Egress"]
      and not spec.get("egress") and not spec.get("ingress"))
raise SystemExit(0 if ok else 1)
'
}

exts09_labels_unchanged() {
  local ns expected current
  for ns in kube-system catalog checkout; do
    [ -s "$EXTS09_DATA/labels-$ns" ] \
      || { grade_invalid "ex-ts-09 baseline labels-$ns missing" || true; return 2; }
    expected="$(cat "$EXTS09_DATA/labels-$ns")"
    current="$(kctx get namespace "$ns" -o json 2>/dev/null | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["metadata"].get("labels", {}), sort_keys=True))
')" || return 1
    [ "$current" = "$expected" ] || return 1
  done
  [ "$(kctx -n checkout get pods -l app=cart -o name 2>/dev/null | wc -l)" -ge 1 ] && \
  [ "$(kctx -n catalog get pods -l app=pricing -o name 2>/dev/null | wc -l)" -ge 1 ]
}

exts09_dns_ok() {
  exts09_cart_exec 12 nslookup pricing.catalog.svc.cluster.local >/dev/null 2>&1
}

exts09_pricing_ok() {
  exts09_cart_exec 12 wget -q -O - -T 4 http://pricing.catalog.svc.cluster.local/ 2>/dev/null \
    | grep -Fxq pricing-ok
}

# Connect by ClusterIP so that the result does not depend on DNS.
exts09_denied() { # <namespace> <service>
  local ip out rc=0
  ip="$(kctx -n "$1" get svc "$2" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" || return 1
  [ -n "$ip" ] || return 1
  svc_has_endpoints "$1" "$2" || return 1
  out="$(exts09_cart_exec 10 wget -q -O /dev/null -T 4 "http://$ip/" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Eqi 'timed out'
}

_python3_require || true

criterion 1 "NetworkPolicy default-deny-egress is unchanged" \
  "exts09_default_deny_unchanged"

criterion 1 "namespace labels are unchanged" \
  "exts09_labels_unchanged"

criterion 2 "실측: cart resolves pricing.catalog.svc.cluster.local" \
  "exts09_dns_ok"

criterion 2 "실측: cart gets an HTTP answer from pricing" \
  "exts09_pricing_ok"

criterion 1 "실측: cart cannot reach inventory" \
  "exts09_denied catalog inventory"

criterion 1 "실측: cart cannot reach other Services (ingress controller)" \
  "exts09_denied ingress-nginx ingress-nginx-controller"

grade_finish
