#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-03
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" telemetry edge-ingest edge-other
kctx label namespace edge-ingest team=edge --overwrite >/dev/null
kctx label namespace edge-other team=batch --overwrite >/dev/null

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: collector
  namespace: telemetry
spec:
  replicas: 1
  selector:
    matchLabels: {app: collector}
  template:
    metadata:
      labels: {app: collector}
    spec:
      containers:
        - name: collector
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /www/data /www/admin
              echo "collector data endpoint" > /www/data/index.html
              echo "collector admin endpoint" > /www/admin/index.html
              httpd -p 8080 -h /www/data
              exec httpd -f -p 9090 -h /www/admin
          ports:
            - {name: data, containerPort: 8080}
            - {name: admin, containerPort: 9090}
          readinessProbe:
            tcpSocket: {port: 8080}
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: collector
  namespace: telemetry
spec:
  selector: {app: collector}
  ports:
    - {name: data, port: 8080, targetPort: 8080}
    - {name: admin, port: 9090, targetPort: 9090}
---
apiVersion: v1
kind: Pod
metadata:
  name: admin-shell
  namespace: telemetry
  labels: {role: admin}
spec:
  containers:
    - {name: shell, image: busybox:1.36, command: ["sh", "-c", "sleep infinity"]}
---
apiVersion: v1
kind: Pod
metadata:
  name: app-shell
  namespace: telemetry
  labels: {role: app}
spec:
  containers:
    - {name: shell, image: busybox:1.36, command: ["sh", "-c", "sleep infinity"]}
---
apiVersion: v1
kind: Pod
metadata:
  name: shipper
  namespace: edge-ingest
  labels: {app: shipper}
spec:
  containers:
    - {name: shell, image: busybox:1.36, command: ["sh", "-c", "sleep infinity"]}
---
apiVersion: v1
kind: Pod
metadata:
  name: shipper
  namespace: edge-other
  labels: {app: shipper}
spec:
  containers:
    - {name: shell, image: busybox:1.36, command: ["sh", "-c", "sleep infinity"]}
EOF

wait_deploy telemetry collector 180s || die "ex-sn-03 collector가 준비되지 않았습니다."
wait_pod telemetry admin-shell 120s || die "ex-sn-03 admin-shell이 준비되지 않았습니다."
wait_pod telemetry app-shell 120s || die "ex-sn-03 app-shell이 준비되지 않았습니다."
wait_pod edge-ingest shipper 120s || die "ex-sn-03 edge-ingest/shipper가 준비되지 않았습니다."
wait_pod edge-other shipper 120s || die "ex-sn-03 edge-other/shipper가 준비되지 않았습니다."
