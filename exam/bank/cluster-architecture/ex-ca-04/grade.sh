#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-04

EXCA04_REQUEST="$CKA_STATE_DIR/question-data/ex-ca-04/dana.csr"
EXCA04_CERT="$CKA_WORK_DIR/ex-ca-04/dana.crt"

exca04_csr_check() { # <spec|request|issued|file>
  local json
  _python3_require || return $?
  if [ "$1" = request ] && [ ! -s "$EXCA04_REQUEST" ]; then
    grade_invalid "ex-ca-04 baseline CSR missing" || true
    return 2
  fi
  json="$(_resource_json csr dana-csr -)" || return 1
  printf '%s' "$json" | python3 -c '
import base64, json, sys
mode, request_path, cert_path = sys.argv[1:4]
csr = json.load(sys.stdin)
spec = csr.get("spec", {})
status = csr.get("status", {})
def pem(text):
    return "".join(line.strip() for line in text.strip().splitlines())
if mode == "spec":
    ok = (spec.get("signerName") == "kubernetes.io/kube-apiserver-client"
          and spec.get("usages") == ["client auth"]
          and spec.get("expirationSeconds") == 86400)
elif mode == "request":
    sent = base64.b64decode(spec.get("request", "")).decode("utf-8", "replace")
    ok = pem(sent) == pem(open(request_path, encoding="utf-8").read())
elif mode == "issued":
    conds = status.get("conditions", [])
    ok = (any(c.get("type") == "Approved" and c.get("status") == "True" for c in conds)
          and not any(c.get("type") in ("Denied", "Failed") for c in conds)
          and bool(status.get("certificate")))
else:
    issued = base64.b64decode(status.get("certificate", "")).decode("utf-8", "replace")
    try:
        saved = open(cert_path, encoding="utf-8").read()
    except OSError:
        raise SystemExit(1)
    ok = bool(issued) and "BEGIN CERTIFICATE" in saved and pem(saved) == pem(issued)
raise SystemExit(0 if ok else 1)
' "$1" "$EXCA04_REQUEST" "$EXCA04_CERT"
}

exca04_rbac() {
  jp_eq rolebinding dana-log-reader audit-zone '{.roleRef.kind}/{.roleRef.name}' Role/log-reader && \
  jp_relation_has rolebinding dana-log-reader audit-zone \
    '{range .subjects[*]}{.kind}{"|"}{.name}{"\n"}{end}' 'User|dana' && \
  [ "$(kctx auth can-i get pods -n audit-zone --as dana 2>/dev/null)" = yes ] && \
  [ "$(kctx auth can-i list pods -n audit-zone --as dana 2>/dev/null)" = yes ] && \
  [ "$(kctx auth can-i get pods --subresource=log -n audit-zone --as dana 2>/dev/null)" = yes ] && \
  [ "$(kctx auth can-i delete pods -n audit-zone --as dana 2>/dev/null)" = no ] && \
  [ "$(kctx auth can-i list pods -n default --as dana 2>/dev/null)" = no ]
}

_python3_require || true

criterion 1 "CSR dana-csr uses the kube-apiserver-client signer, client auth, 86400s" \
  "exca04_csr_check spec"

criterion 1 "CSR dana-csr carries the provided dana.csr request" \
  "exca04_csr_check request"

criterion 2 "CSR dana-csr is Approved and a certificate was issued" \
  "exca04_csr_check issued"

criterion 2 "dana.crt holds the issued certificate in PEM format" \
  "exca04_csr_check file"

criterion 2 "dana can get/list Pods and read Pod logs in audit-zone only, but cannot delete Pods" \
  "exca04_rbac"

grade_finish
