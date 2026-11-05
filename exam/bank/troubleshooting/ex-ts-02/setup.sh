#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" billing

# DB_PASSWORD references key "password", but the Secret stores the value under
# "db-password". The kubelet cannot build the container environment, so every
# Pod stays in CreateContainerConfigError.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: invoice-db
  namespace: billing
type: Opaque
stringData:
  username: invoice_svc
  db-password: Tr4nsact10n-Ledger
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invoice-api
  namespace: billing
spec:
  replicas: 2
  selector:
    matchLabels: {app: invoice-api}
  template:
    metadata:
      labels: {app: invoice-api}
    spec:
      containers:
        - name: api
          image: nginx:1.29
          ports:
            - containerPort: 80
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: invoice-db
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: invoice-db
                  key: password
EOF

for _ in $(seq 1 60); do
  reasons="$(kctx -n billing get pods -l app=invoice-api \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null || true)"
  [ "$(printf '%s\n' "$reasons" | grep -cx CreateContainerConfigError)" -eq 2 ] && break
  sleep 2
done
[ "$(printf '%s\n' "$reasons" | grep -cx CreateContainerConfigError)" -eq 2 ] \
  || die "ex-ts-02 baseline Pod가 CreateContainerConfigError가 아닙니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n billing get secret invoice-db -o json | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(
    json.dumps(obj.get("data", {}), sort_keys=True).encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/$QID/secret-fingerprint"
