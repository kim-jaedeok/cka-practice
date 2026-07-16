#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-08
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" monitor
workdir_reset "$QID"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: idle-api
  namespace: monitor
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: idle-worker
  namespace: monitor
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: metrics-crunch
  namespace: monitor
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sha256sum /dev/zero"]
      resources:
        requests: {cpu: 100m, memory: 16Mi}
        limits: {cpu: 500m, memory: 64Mi}
EOF

wait_pod monitor idle-api
wait_pod monitor idle-worker
wait_pod monitor metrics-crunch
info "메트릭이 수집될 때까지 30~60초 기다린 후 kubectl top을 사용하세요."
