#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-05
require_cluster
command -v openssl >/dev/null 2>&1 || die "ex-sn-05: openssl이 필요합니다."
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" secure-vault

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-ui
  namespace: secure-vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-ui
  template:
    metadata:
      labels:
        app: vault-ui
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /www && echo vault-ui-ok > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: vault-ui
  namespace: secure-vault
spec:
  selector:
    app: vault-ui
  ports:
    - port: 80
      targetPort: 8080
EOF

# The certificate that the security team issued for the site.
work="$CKA_WORK_DIR/$QID"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$work/vault.key" -out "$work/vault.crt" \
  -subj "/CN=vault.secure.test/O=secure-vault" \
  -addext "subjectAltName=DNS:vault.secure.test" >/dev/null 2>&1
chmod 600 "$work/vault.key"

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
openssl x509 -in "$work/vault.crt" -outform der | sha256sum | cut -d' ' -f1 \
  > "$CKA_STATE_DIR/question-data/$QID/cert-sha256"

wait_deploy secure-vault vault-ui || die "ex-sn-05 vault-ui가 Ready가 아닙니다."
