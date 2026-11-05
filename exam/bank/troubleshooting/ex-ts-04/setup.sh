#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-04
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" storefront

# The Service selects only app=shop. The canary Pods carry the same label and
# answer 503, so kube-proxy sends part of the traffic to them.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-web-conf
  namespace: storefront
data:
  default.conf: |
    server {
      listen 80;
      location / { default_type text/plain; return 200 "shop-web stable\n"; }
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-canary-conf
  namespace: storefront
data:
  default.conf: |
    server {
      listen 80;
      location / { default_type text/plain; return 503 "shop-canary not released\n"; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-web
  namespace: storefront
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, track: stable}
  template:
    metadata:
      labels: {app: shop, track: stable}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: conf
          configMap:
            name: shop-web-conf
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-canary
  namespace: storefront
spec:
  replicas: 1
  selector:
    matchLabels: {app: shop, track: canary}
  template:
    metadata:
      labels: {app: shop, track: canary}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: conf
          configMap:
            name: shop-canary-conf
---
apiVersion: v1
kind: Service
metadata:
  name: shop-svc
  namespace: storefront
spec:
  selector: {app: shop}
  ports:
    - port: 80
      targetPort: 80
EOF

wait_deploy storefront shop-web 180s || die "ex-ts-04 shop-web가 준비되지 않았습니다."
wait_deploy storefront shop-canary 180s || die "ex-ts-04 shop-canary가 준비되지 않았습니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n storefront get deploy shop-web -o json | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
print(obj["metadata"]["uid"] + "|" + hashlib.sha256(json.dumps(
    [obj["spec"]["replicas"], obj["spec"]["selector"], obj["spec"]["template"]],
    sort_keys=True).encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/$QID/shop-web-fingerprint"
