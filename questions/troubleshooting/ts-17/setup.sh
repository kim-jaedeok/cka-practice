#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-17
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" node-agents

# A hostNetwork container port is also a host port. The scheduler therefore
# refuses a second Pod on cka-worker that declares the same port.
kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: legacy-agent
  namespace: node-agents
  labels: {app: legacy-agent}
spec:
  hostNetwork: true
  nodeSelector: {kubernetes.io/hostname: cka-worker}
  containers:
    - name: agent
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /www && echo legacy > /www/index.html && exec httpd -f -p 9180 -h /www"]
      ports:
        - containerPort: 9180
      readinessProbe:
        tcpSocket: {port: 9180}
        periodSeconds: 2
EOF
wait_pod node-agents legacy-agent 120s \
  || die "ts-17 baseline legacy-agent가 Ready가 되지 않았습니다."

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
      command: ["sh", "-c", "mkdir -p /www && echo exporter > /www/index.html && exec httpd -f -p 9180 -h /www"]
      ports:
        - containerPort: 9180
      readinessProbe:
        tcpSocket: {port: 9180}
        periodSeconds: 2
EOF

for _ in $(seq 1 30); do
  reason="$(kctx -n node-agents get pod metrics-exporter \
    -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}')"
  [ "$reason" = Unschedulable ] && break
  sleep 1
done
[ "$reason" = Unschedulable ] \
  || die "ts-17 baseline metrics-exporter가 port 충돌로 Pending이 아닙니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n node-agents get pod legacy-agent -o jsonpath='{.metadata.uid}' \
  > "$CKA_STATE_DIR/question-data/$QID/legacy-uid"
