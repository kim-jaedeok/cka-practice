#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-06

EXSN06_DATA="$CKA_STATE_DIR/question-data/ex-sn-06"

exsn06_external_name() {
  kctx -n shop-frontend get svc payments -o json 2>/dev/null | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]
# A selector is ignored for ExternalName (kubectl create service externalname
# adds one), so it is not checked.
ok = (spec.get("type") == "ExternalName"
      and spec.get("externalName", "").rstrip(".") == "payments-api.payments-core.svc.cluster.local")
raise SystemExit(0 if ok else 1)
'
}

exsn06_legacy_gone() {
  ! res_exists deploy payments-legacy shop-frontend \
    && res_absent_sel pods shop-frontend app=payments-legacy
}

exsn06_client_reaches_v2() {
  deploy_ready shop-frontend web-client 1 || return 1
  timeout 15 kubectl --context "$CKA_CONTEXT" -n shop-frontend exec deploy/web-client -c client -- \
    wget -q -O - -T 4 http://payments:8080/ 2>/dev/null | grep -Fxq 'payments-api v2'
}

exsn06_core_unchanged() {
  local expected current
  [ -s "$EXSN06_DATA/core-fingerprint" ] \
    || { grade_invalid "ex-sn-06 baseline core-fingerprint missing" || true; return 2; }
  expected="$(cat "$EXSN06_DATA/core-fingerprint")"
  current="$(
    kctx -n payments-core get deploy payments-api -o jsonpath='{.metadata.uid}{"|"}{.metadata.generation}{"\n"}' 2>/dev/null
    kctx -n payments-core get svc payments-api -o jsonpath='{.metadata.uid}{"|"}{.spec.selector.app}{"|"}{.spec.ports[0].port}{"\n"}' 2>/dev/null
  )"
  [ "$current" = "$expected" ]
}

_python3_require || true

criterion 2 "Service payments is an ExternalName for payments-api.payments-core" \
  "exsn06_external_name"

criterion 1 "Deployment payments-legacy and its Pods are gone" \
  "exsn06_legacy_gone"

criterion 2 "실측: web-client gets the payments-api answer from http://payments:8080/" \
  "exsn06_client_reaches_v2"

criterion 1 "namespace payments-core is unchanged" \
  "exsn06_core_unchanged"

grade_finish
