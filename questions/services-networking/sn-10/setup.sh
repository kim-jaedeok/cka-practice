#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

QID=sn-10
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" sn10-checkout sn10-monitoring sn10-untrusted sn10-catalog

kctx label namespace sn10-monitoring \
  'cka-practice/sn-10-role=monitoring' --overwrite >/dev/null
kctx label namespace sn10-untrusted \
  'cka-practice/sn-10-role=untrusted' --overwrite >/dev/null
kctx label namespace sn10-catalog \
  'cka-practice/sn-10-role=catalog' --overwrite >/dev/null

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: checkout
  namespace: sn10-checkout
  labels:
    app: checkout
spec:
  containers:
    - name: checkout
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - mkdir -p /www;
          echo cka-sn10-checkout > /www/index.html;
          exec httpd -f -p 8080 -h /www
      ports:
        - name: http
          containerPort: 8080
      readinessProbe:
        httpGet:
          path: /
          port: http
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: sn10-checkout
spec:
  selector:
    app: checkout
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: sn10-monitoring
  labels:
    access: monitor
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: other
  namespace: sn10-monitoring
  labels:
    access: other
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: sn10-untrusted
  labels:
    access: monitor
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  namespace: sn10-catalog
  labels:
    app: catalog
spec:
  containers:
    - name: server
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - mkdir -p /www;
          echo cka-sn10-catalog > /www/index.html;
          exec httpd -f -p 8080 -h /www
      ports:
        - name: http
          containerPort: 8080
      readinessProbe:
        httpGet:
          path: /
          port: http
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-svc
  namespace: sn10-catalog
spec:
  selector:
    app: catalog
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: admin
  namespace: sn10-catalog
  labels:
    app: admin
spec:
  containers:
    - name: server
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - mkdir -p /www;
          echo cka-sn10-admin > /www/index.html;
          exec httpd -f -p 8080 -h /www
      ports:
        - name: http
          containerPort: 8080
      readinessProbe:
        httpGet:
          path: /
          port: http
---
apiVersion: v1
kind: Service
metadata:
  name: admin-svc
  namespace: sn10-catalog
spec:
  selector:
    app: admin
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF

wait_pod sn10-checkout checkout
wait_pod sn10-monitoring probe
wait_pod sn10-monitoring other
wait_pod sn10-untrusted probe
wait_pod sn10-catalog catalog
wait_pod sn10-catalog admin
