#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$CKA_ROOT/lib/controllers.sh"

CA09_STATE_DIR="$CKA_STATE_DIR/question-data/ca-09"
CA09_TAMPERED=0

ca09_infra_fingerprint() {
  {
    kctx -n cert-manager get deployment,service,serviceaccount -o json 2>/dev/null || return 1
    kctx get clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration -o json 2>/dev/null || return 1
    kctx -n cka-controller-system get issuer,certificate cka-ca09-sentinel -o json 2>/dev/null || return 1
  } | python3 -c '
import hashlib, json, sys
decoder=json.JSONDecoder(); text=sys.stdin.read(); pos=0; objects=[]
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj,pos=decoder.raw_decode(text,pos)
    for item in obj.get("items",[obj]):
        meta=item.get("metadata",{}); name=meta.get("name",""); ns=meta.get("namespace","")
        if ns == "cert-manager" or name.startswith("cert-manager") or name == "cka-ca09-sentinel":
            objects.append({"apiVersion":item.get("apiVersion"),"kind":item.get("kind"),
              "namespace":ns,"name":name,"uid":meta.get("uid"),"spec":item.get("spec"),
              "rules":item.get("rules"),"roleRef":item.get("roleRef"),
              "subjects":item.get("subjects"),"webhooks":item.get("webhooks")})
payload=json.dumps(sorted(objects,key=lambda x:(x["kind"] or "",x["namespace"],x["name"])),sort_keys=True,separators=(",",":"))
print(hashlib.sha256(payload.encode()).hexdigest())
'
}

ca09_infra_matches() {
  local expected current
  expected="$(tr -d '\r\n' < "$CA09_STATE_DIR/infra.sha256" 2>/dev/null)" || return 2
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 2
  current="$(ca09_infra_fingerprint)" || return 1
  [ "$current" = "$expected" ]
}

ca09_guard() { [ "$CA09_TAMPERED" -eq 0 ]; }

ca09_condition_current() { # kind name namespace condition
  local json
  json="$(_resource_json "$1" "$2" "$3")" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
obj=json.load(sys.stdin); wanted=sys.argv[1]; generation=obj.get("metadata",{}).get("generation")
ok=any(c.get("type")==wanted and c.get("status")=="True" and c.get("observedGeneration")==generation
       for c in obj.get("status",{}).get("conditions",[]))
raise SystemExit(0 if ok else 1)
' "$4"
}

ca09_issuer_exact() {
  local json
  json="$(_resource_json issuer operator-selfsigned operators)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
spec=json.load(sys.stdin).get("spec",{})
raise SystemExit(0 if spec == {"selfSigned": {}} else 1)
'
}

ca09_certificate_exact() {
  local json
  json="$(_resource_json certificate db-api-tls operators)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
spec=json.load(sys.stdin).get("spec",{})
ok=(spec.get("secretName")=="db-api-tls" and spec.get("commonName")=="db.operators.svc"
    and spec.get("dnsNames")==["db.operators.svc"] and spec.get("duration") in {"24h","24h0m0s"}
    and spec.get("renewBefore") in {"8h","8h0m0s"}
    and spec.get("privateKey",{}).get("algorithm")=="RSA"
    and spec.get("privateKey",{}).get("size")==2048
    and set(spec.get("usages",[]))=={"digital signature","key encipherment","server auth"}
    and len(spec.get("usages",[]))==3
    and spec.get("issuerRef",{}).get("name")=="operator-selfsigned"
    and spec.get("issuerRef",{}).get("kind","Issuer")=="Issuer"
    and spec.get("issuerRef",{}).get("group","cert-manager.io")=="cert-manager.io")
raise SystemExit(0 if ok else 1)
'
}

ca09_owned_request_ready() {
  local cert_uid requests
  cert_uid="$(_jp_get certificate db-api-tls operators '{.metadata.uid}')" || return 1
  requests="$(kctx -n operators get certificaterequests -o json 2>/dev/null)" || return 1
  printf '%s' "$requests" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[]); uid=sys.argv[1]; owned=[]
for item in items:
    refs=item.get("metadata",{}).get("ownerReferences",[])
    if any(r.get("uid")==uid and r.get("kind")=="Certificate" and r.get("controller") is True for r in refs):
        owned.append(item)
ok=len(owned)==1
if ok:
    ref=owned[0].get("spec",{}).get("issuerRef",{})
    ok=(ref.get("name")=="operator-selfsigned" and ref.get("kind","Issuer")=="Issuer"
        and any(c.get("type")=="Ready" and c.get("status")=="True"
                for c in owned[0].get("status",{}).get("conditions",[])))
raise SystemExit(0 if ok else 1)
' "$cert_uid"
}

ca09_tls_secret_reconciled() {
  [ "$(_jp_get secret db-api-tls operators '{.type}')" = kubernetes.io/tls ] || return 1
  [ "$(_jp_get secret db-api-tls operators '{.metadata.annotations.cert-manager\.io/certificate-name}')" = db-api-tls ] || return 1
  controller_tls_secret_valid operators db-api-tls db.operators.svc || return 1
  [ -n "$(_jp_get certificate db-api-tls operators '{.status.revision}')" ]
}

[ "${CKA_QUESTION_SOURCE_ONLY:-0}" = 1 ] && return 0

grade_init ca-09

if [ ! -r "$CA09_STATE_DIR/infra.sha256" ]; then
  grade_invalid "ca-09 trusted controller baseline missing" || true
elif ! ca09_infra_matches; then
  CA09_TAMPERED=1
elif ! deploy_ready cert-manager cert-manager 1 \
    || ! deploy_ready cert-manager cert-manager-cainjector 1 \
    || ! deploy_ready cert-manager cert-manager-webhook 1 \
    || ! svc_has_endpoints cert-manager cert-manager-webhook \
    || ! controller_cert_manager_runtime_locked; then
  grade_invalid "unchanged cert-manager control plane unavailable" || true
fi

criterion 2 "Issuer spec가 정확하고 현재 generation이 Ready=True" \
  "ca09_guard && ca09_issuer_exact && ca09_condition_current issuer operator-selfsigned operators Ready"

criterion 3 "Certificate의 identity, 기간, 키, usage, issuerRef가 정확" \
  "ca09_guard && ca09_certificate_exact"

criterion 2 "Certificate controller가 현재 generation을 Ready=True로 reconcile" \
  "ca09_guard && ca09_condition_current certificate db-api-tls operators Ready"

criterion 1 "Certificate가 소유한 단 하나의 CertificateRequest가 Ready" \
  "ca09_guard && ca09_owned_request_ready"

criterion 2 "controller가 만든 TLS Secret의 SAN과 인증서/개인키가 일치" \
  "ca09_guard && ca09_tls_secret_reconciled"

grade_finish
