#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n node-agents delete pod metrics-exporter --wait=true --timeout=90s >/dev/null
kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: metrics-exporter
  namespace: node-agents
  labels: {app: metrics-exporter}
spec:
  hostNetwork: true
  nodeSelector: {kubernetes.io/hostname: cka-worker}
  containers:
    - name: exporter
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /www && echo exporter > /www/index.html && exec httpd -f -p 9181 -h /www"]
      ports:
        - containerPort: 9181
      readinessProbe:
        tcpSocket: {port: 9181}
        periodSeconds: 2
EOF
wait_pod node-agents metrics-exporter 120s
