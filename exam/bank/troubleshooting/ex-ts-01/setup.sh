#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" ledger

# The Deployment names a ServiceAccount that does not exist. The ServiceAccount
# admission plugin rejects every Pod, so the ReplicaSet only records
# FailedCreate events and no Pod object ever appears.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audit-writer
  namespace: ledger
spec:
  replicas: 2
  selector:
    matchLabels: {app: audit-writer}
  template:
    metadata:
      labels: {app: audit-writer}
    spec:
      serviceAccountName: audit-sa
      containers:
        - name: writer
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF

for _ in $(seq 1 30); do
  if kctx -n ledger get rs -l app=audit-writer -o name 2>/dev/null | grep -q .; then
    break
  fi
  sleep 1
done
sleep 3
[ -z "$(kctx -n ledger get pods -l app=audit-writer -o name 2>/dev/null)" ] \
  || die "ex-ts-01 baseline은 Pod가 없어야 합니다."
