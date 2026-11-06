#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
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
  tls:
    - hosts:
        - vault.secure.test
      secretName: vault-tls
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

for _ in $(seq 1 30); do
  curl -sk -m 3 --resolve vault.secure.test:8443:127.0.0.1 https://vault.secure.test:8443/ \
    | grep -q vault-ui-ok && exit 0
  sleep 2
done
exit 1
