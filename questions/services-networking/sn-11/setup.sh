#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-11
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" fabric
workdir_reset "$QID"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: trainer-a
  namespace: fabric
spec:
  nodeName: cka-worker
  containers:
    - name: trainer
      image: busybox:1.36
      command: ["sh", "-c", "sleep 14400"]
---
apiVersion: v1
kind: Pod
metadata:
  name: trainer-b
  namespace: fabric
spec:
  nodeName: cka-worker2
  containers:
    - name: trainer
      image: busybox:1.36
      command: ["sh", "-c", "sleep 14400"]
EOF
wait_pod fabric trainer-a 120s || die "sn-11 baseline trainer-a가 Ready가 아닙니다."
wait_pod fabric trainer-b 120s || die "sn-11 baseline trainer-b가 Ready가 아닙니다."
