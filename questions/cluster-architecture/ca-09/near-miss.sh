#!/usr/bin/env bash
# Issuer is valid, but the Certificate does not satisfy the requested identity.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
source "$CKA_ROOT/lib/cell.sh"
cell_activate ca-09 operator-cell
kctx apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: operator-selfsigned
  namespace: operators
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: db-api-tls
  namespace: operators
spec:
  secretName: manually-named-tls
  dnsNames: [wrong.operators.svc]
  issuerRef:
    name: operator-selfsigned
    kind: Issuer
EOF
kctx -n operators wait --for=condition=Ready issuer/operator-selfsigned --timeout=90s >/dev/null
