#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-09
require_cluster
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" catalog checkout

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  namespace: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pricing
  template:
    metadata:
      labels:
        app: pricing
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /www && echo pricing-ok > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: pricing
  namespace: catalog
spec:
  selector:
    app: pricing
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
  namespace: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inventory
  template:
    metadata:
      labels:
        app: inventory
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /www && echo inventory-ok > /www/index.html && exec httpd -f -p 8080 -h /www"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: inventory
  namespace: catalog
spec:
  selector:
    app: inventory
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
  namespace: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cart
  template:
    metadata:
      labels:
        app: cart
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: cart
          image: busybox:1.36
          command: ["sleep", "3600000"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: checkout
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cart-egress
  namespace: checkout
spec:
  podSelector:
    matchLabels:
      app: cart
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: catalog
          podSelector:
            matchLabels:
              app: pricing
      ports:
        - protocol: TCP
          port: 80
EOF

wait_deploy catalog pricing || die "ex-ts-09 pricing이 Ready가 아닙니다."
wait_deploy catalog inventory || die "ex-ts-09 inventory가 Ready가 아닙니다."
wait_deploy checkout cart || die "ex-ts-09 cart가 Ready가 아닙니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
for ns in kube-system catalog checkout; do
  kctx get namespace "$ns" -o json | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["metadata"].get("labels", {}), sort_keys=True))
' > "$CKA_STATE_DIR/question-data/$QID/labels-$ns"
done
