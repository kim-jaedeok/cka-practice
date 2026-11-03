#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-16
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" inventory

# nginx serves "/" but not "/healthz", so the readiness probe always fails and
# the EndpointSlice keeps both Pod addresses with ready=false.
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stock-api
  namespace: inventory
spec:
  replicas: 2
  selector:
    matchLabels: {app: stock-api}
  template:
    metadata:
      labels: {app: stock-api}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /healthz
              port: 80
            periodSeconds: 2
            failureThreshold: 1
---
apiVersion: v1
kind: Service
metadata:
  name: stock-svc
  namespace: inventory
spec:
  selector: {app: stock-api}
  ports:
    - port: 80
      targetPort: 80
EOF

kctx -n inventory wait --for=jsonpath='{.status.phase}'=Running pods -l app=stock-api \
  --timeout=120s >/dev/null \
  || die "ts-16 baseline Pod가 Running이 되지 않았습니다."
sleep 4
ready="$(kctx -n inventory get endpointslices -l kubernetes.io/service-name=stock-svc \
  -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}')"
[ -n "$ready" ] && ! grep -qx true <<< "$ready" \
  || die "ts-16 baseline은 ready가 아닌 endpoint만 가져야 합니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n inventory get svc stock-svc -o json | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
spec = {k: obj["spec"].get(k) for k in ("selector", "ports", "type")}
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(
    json.dumps(spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/$QID/service-fingerprint"
