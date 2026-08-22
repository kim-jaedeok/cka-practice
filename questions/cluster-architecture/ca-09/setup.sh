#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/controllers.sh"

QID=ca-09
STATE_DIR="$CKA_STATE_DIR/question-data/$QID"
CA09_SETUP_STAGE="initial validation"

ca09_setup_error() { # <exit-code> <line>
  local rc="$1" line="$2"
  trap - ERR
  err "ca-09 setup failed during '$CA09_SETUP_STAGE' (line $line, exit $rc)"
  exit "$rc"
}
trap 'ca09_setup_error "$?" "$LINENO"' ERR

ca09_infra_fingerprint() {
  {
    kctx -n cert-manager get deployment,service,serviceaccount -o json
    kctx get clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration -o json
    kctx -n cka-controller-system get issuer,certificate cka-ca09-sentinel -o json
  } | python3 -c '
import hashlib, json, sys
decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; objects = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace(): pos += 1
    if pos >= len(text): break
    obj, pos = decoder.raw_decode(text, pos)
    values = obj.get("items", [obj])
    for item in values:
        meta = item.get("metadata", {})
        name = meta.get("name", ""); ns = meta.get("namespace", "")
        if ns == "cert-manager" or name.startswith("cert-manager") or name == "cka-ca09-sentinel":
            objects.append({
                "apiVersion": item.get("apiVersion"), "kind": item.get("kind"),
                "namespace": ns, "name": name, "uid": meta.get("uid"),
                "spec": item.get("spec"), "rules": item.get("rules"),
                "roleRef": item.get("roleRef"), "subjects": item.get("subjects"),
                "webhooks": item.get("webhooks"),
            })
payload = json.dumps(sorted(objects, key=lambda x:(x["kind"] or "",x["namespace"],x["name"])),
                     sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(payload.encode()).hexdigest())
'
}

controller_require_disposable_cell "$QID" operator-cell
require_cluster_readonly
if ! controller_cell_status "$QID" operator-cell >/dev/null 2>&1; then
  CA09_SETUP_STAGE="cert-manager offline install"
  controller_cell_prepare "$QID" operator-cell
  CA09_SETUP_STAGE="cert-manager readiness and locked-runtime validation"
  controller_cell_activate "$QID" operator-cell
fi
CA09_SETUP_STAGE="candidate namespace reset"
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" operators
kctx create namespace cka-controller-system --dry-run=client -o yaml | kctx apply -f - >/dev/null

CA09_SETUP_STAGE="cert-manager sentinel creation"
kctx apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: cka-ca09-sentinel
  namespace: cka-controller-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cka-ca09-sentinel
  namespace: cka-controller-system
spec:
  secretName: cka-ca09-sentinel-tls
  dnsNames:
    - controller-sentinel.cka-controller-system.svc
  issuerRef:
    name: cka-ca09-sentinel
    kind: Issuer
EOF

CA09_SETUP_STAGE="cert-manager sentinel reconciliation"
kctx -n cka-controller-system wait --for=condition=Ready \
  issuer/cka-ca09-sentinel certificate/cka-ca09-sentinel --timeout=120s >/dev/null
controller_tls_secret_valid cka-controller-system cka-ca09-sentinel-tls \
  controller-sentinel.cka-controller-system.svc \
  || die "cert-manager sentinel TLS reconciliation failed"

CA09_SETUP_STAGE="trusted infrastructure fingerprint"
umask 077
mkdir -p "$STATE_DIR"
ca09_infra_fingerprint > "$STATE_DIR/infra.sha256"
grep -Eq '^[0-9a-f]{64}$' "$STATE_DIR/infra.sha256" \
  || die "ca-09 trusted infrastructure fingerprint failed"
trap - ERR
