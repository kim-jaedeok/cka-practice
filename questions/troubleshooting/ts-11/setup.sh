#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-11
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" shop

kctx apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-content
  namespace: shop
data:
  index.html: "checkout service ready\n"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 1
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
      volumes:
        - name: content
          configMap:
            name: checkout-content
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-svc
  namespace: shop
spec:
  selector: {app: checkout}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
  namespace: shop
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: checkout
                port:
                  number: 8080
EOF

wait_deploy shop checkout
