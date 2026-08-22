#!/usr/bin/env bash
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
  secretName: db-api-tls
  commonName: db.operators.svc
  dnsNames:
    - db.operators.svc
  duration: 24h
  renewBefore: 8h
  privateKey:
    algorithm: RSA
    size: 2048
  usages:
    - digital signature
    - key encipherment
    - server auth
  issuerRef:
    name: operator-selfsigned
    kind: Issuer
EOF

kctx -n operators wait --for=condition=Ready \
  issuer/operator-selfsigned certificate/db-api-tls --timeout=120s >/dev/null
