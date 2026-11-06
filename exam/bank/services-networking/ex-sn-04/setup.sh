#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-04
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" node-agents

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: stats-agent
  namespace: node-agents
spec:
  selector:
    matchLabels:
      app: stats-agent
  template:
    metadata:
      labels:
        app: stats-agent
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: agent
          image: busybox:1.36
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          command:
            - sh
            - -c
            - |
              mkdir -p /www /metrics
              echo "agent on $NODE_NAME" > /www/index.html
              echo "metrics node=$NODE_NAME" > /metrics/index.html
              httpd -p 8080 -h /www
              exec httpd -f -p 9100 -h /metrics
          ports:
            - name: web
              containerPort: 8080
            - name: metrics
              containerPort: 9100
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reporter
  namespace: node-agents
spec:
  replicas: 2
  selector:
    matchLabels:
      app: reporter
  template:
    metadata:
      labels:
        app: reporter
    spec:
      terminationGracePeriodSeconds: 2
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: reporter
              topologyKey: kubernetes.io/hostname
      containers:
        - name: reporter
          image: busybox:1.36
          command: ["sleep", "3600000"]
EOF

kctx -n node-agents rollout status ds/stats-agent --timeout=120s >/dev/null \
  || die "ex-sn-04 stats-agent DaemonSet이 Ready가 아닙니다."
wait_deploy node-agents reporter || die "ex-sn-04 reporter가 Ready가 아닙니다."
