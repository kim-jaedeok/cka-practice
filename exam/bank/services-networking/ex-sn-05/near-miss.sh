#!/usr/bin/env bash
# Near-miss fixture: the TLS Secret and the route exist, but the Ingress has no
# tls section, so the controller serves its default certificate.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
W="$CKA_WORK_DIR/ex-sn-05"

kctx -n secure-vault create secret tls vault-tls --cert="$W/vault.crt" --key="$W/vault.key" >/dev/null
kctx apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: secure-vault
spec:
  ingressClassName: nginx
  rules:
    - host: vault.secure.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 80
EOF
sleep 8
