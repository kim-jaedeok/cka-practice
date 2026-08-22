#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
source "$CKA_ROOT/lib/controllers.sh"

CA13_STATE_DIR="$CKA_STATE_DIR/question-data/ca-13"
CA13_TAMPERED=0

ca13_probe_fingerprint() {
  kctx -n operator-verify get issuer,certificate install-proof -o json 2>/dev/null | python3 -c '
import hashlib,json,sys
obj=json.load(sys.stdin); values=[]
for item in obj.get("items",[]):
    meta=item.get("metadata",{})
    values.append({"apiVersion":item.get("apiVersion"),"kind":item.get("kind"),
      "name":meta.get("name"),"namespace":meta.get("namespace"),
      "uid":meta.get("uid"),"spec":item.get("spec")})
print(hashlib.sha256(json.dumps(sorted(values,key=lambda x:x["kind"]),
  sort_keys=True,separators=(",",":")).encode()).hexdigest())
'
}

ca13_probe_matches() {
  local expected current
  expected="$(tr -d '\r\n' < "$CA13_STATE_DIR/probe.sha256" 2>/dev/null)" || return 2
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 2
  current="$(ca13_probe_fingerprint)" || return 1
  [ "$current" = "$expected" ]
}

ca13_guard() { [ "$CA13_TAMPERED" -eq 0 ]; }

ca13_crds_exact() {
  local json
  json="$(kctx get crd certificates.cert-manager.io certificaterequests.cert-manager.io \
    issuers.cert-manager.io clusterissuers.cert-manager.io -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
expected={"certificates.cert-manager.io","certificaterequests.cert-manager.io",
          "issuers.cert-manager.io","clusterissuers.cert-manager.io"}
ok={x.get("metadata",{}).get("name") for x in items}==expected
for item in items:
    versions=item.get("spec",{}).get("versions",[])
    conditions=item.get("status",{}).get("conditions",[])
    ok=ok and any(v.get("name")=="v1" and v.get("served") and v.get("storage") for v in versions)
    ok=ok and any(c.get("type")=="Established" and c.get("status")=="True" for c in conditions)
raise SystemExit(0 if ok else 1)
'
}

ca13_probe_ready_current() {
  local json
  json="$(_resource_json certificate install-proof operator-verify)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
obj=json.load(sys.stdin); generation=obj.get("metadata",{}).get("generation")
ok=any(c.get("type")=="Ready" and c.get("status")=="True"
       and c.get("observedGeneration")==generation
       for c in obj.get("status",{}).get("conditions",[]))
raise SystemExit(0 if ok else 1)
'
}

ca13_owned_request_ready() {
  local uid json
  uid="$(_jp_get certificate install-proof operator-verify '{.metadata.uid}')" || return 1
  json="$(kctx -n operator-verify get certificaterequests -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
uid=sys.argv[1]; owned=[]
for item in json.load(sys.stdin).get("items",[]):
    if any(r.get("uid")==uid and r.get("kind")=="Certificate" and r.get("controller") is True
           for r in item.get("metadata",{}).get("ownerReferences",[])):
        owned.append(item)
ok=len(owned)==1 and any(c.get("type")=="Ready" and c.get("status")=="True"
                         for c in owned[0].get("status",{}).get("conditions",[]))
raise SystemExit(0 if ok else 1)
' "$uid"
}

[ "${CKA_QUESTION_SOURCE_ONLY:-0}" = 1 ] && return 0

grade_init ca-13

if [ ! -r "$CA13_STATE_DIR/probe.sha256" ]; then
  grade_invalid "ca-13 trusted reconcile probe baseline missing" || true
elif ! ca13_probe_matches; then
  CA13_TAMPERED=1
fi

criterion 2 "cert-manager 핵심 CRD가 v1 storage/served 및 Established" \
  "ca13_guard && ca13_crds_exact"

criterion 3 "세 Pod가 digest-pinned v1.21.1 이미지를 Never 정책과 실제 imageID로 실행" \
  "ca13_guard && controller_cert_manager_runtime_locked"

criterion 2 "세 Deployment가 현재 generation으로 완전히 Available" \
  "ca13_guard && deploy_ready cert-manager cert-manager 1 && \
   deploy_ready cert-manager cert-manager-cainjector 1 && \
   deploy_ready cert-manager cert-manager-webhook 1"

criterion 1 "webhook Service에 Ready EndpointSlice가 존재" \
  "ca13_guard && svc_has_endpoints cert-manager cert-manager-webhook"

criterion 2 "보호된 Certificate probe의 현재 generation을 Ready로 reconcile" \
  "ca13_guard && ca13_probe_ready_current && ca13_owned_request_ready"

criterion 2 "reconcile된 TLS Secret의 SAN과 인증서/개인키가 일치" \
  "ca13_guard && \
   [ \"\$(_jp_get secret install-proof-tls operator-verify '{.type}')\" = kubernetes.io/tls ] && \
   controller_tls_secret_valid operator-verify install-proof-tls install-proof.operator-verify.svc"

grade_finish
