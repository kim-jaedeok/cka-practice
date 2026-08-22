#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/controllers.sh"

QID=ca-13
STATE_DIR="$CKA_STATE_DIR/question-data/$QID"
ASSET_DEST="$CKA_WORK_DIR/$QID/cert-manager-v1.21.1.yaml"

ca13_probe_fingerprint() {
  kctx -n operator-verify get issuer,certificate install-proof -o json | python3 -c '
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

controller_require_disposable_cell "$QID" operator-cell
require_cluster_readonly
if ! controller_cell_status "$QID" operator-cell >/dev/null 2>&1; then
  controller_cell_cleanup "$QID" operator-cell
  controller_cell_prepare "$QID" operator-cell
  controller_cell_activate "$QID" operator-cell
fi
cleanup_question "$QID"
workdir_reset "$QID"
controller_publish_candidate_asset cert-manager "$ASSET_DEST"
recreate_ns "$QID" operator-verify

kctx apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: install-proof
  namespace: operator-verify
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: install-proof
  namespace: operator-verify
spec:
  secretName: install-proof-tls
  dnsNames:
    - install-proof.operator-verify.svc
  issuerRef:
    name: install-proof
    kind: Issuer
EOF

umask 077
mkdir -p "$STATE_DIR"
ca13_probe_fingerprint > "$STATE_DIR/probe.sha256"
grep -Eq '^[0-9a-f]{64}$' "$STATE_DIR/probe.sha256" \
  || die "ca-13 trusted probe fingerprint failed"

# The controller must genuinely be absent at hand-off.
if kctx -n cert-manager get deployment cert-manager >/dev/null 2>&1; then
  die "ca-13 setup accidentally left the operator installed"
fi
