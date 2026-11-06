#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-06
require_cluster
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" payments-core shop-frontend

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments-core
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: api
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /www && echo 'payments-api v2' > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments-core
spec:
  selector:
    app: payments-api
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-legacy
  namespace: shop-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-legacy
  template:
    metadata:
      labels:
        app: payments-legacy
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: api
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /www && echo 'payments legacy v1' > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: shop-frontend
spec:
  selector:
    app: payments-legacy
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-client
  namespace: shop-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-client
  template:
    metadata:
      labels:
        app: web-client
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: client
          image: busybox:1.36
          command: ["sleep", "3600000"]
EOF

for d in payments-core/payments-api shop-frontend/payments-legacy shop-frontend/web-client; do
  wait_deploy "${d%/*}" "${d#*/}" || die "ex-sn-06 $d 가 Ready가 아닙니다."
done

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
{
  kctx -n payments-core get deploy payments-api -o jsonpath='{.metadata.uid}{"|"}{.metadata.generation}{"\n"}'
  kctx -n payments-core get svc payments-api -o jsonpath='{.metadata.uid}{"|"}{.spec.selector.app}{"|"}{.spec.ports[0].port}{"\n"}'
} > "$CKA_STATE_DIR/question-data/$QID/core-fingerprint"
