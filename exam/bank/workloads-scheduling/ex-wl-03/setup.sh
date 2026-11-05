#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-03
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" cache-tier

# web spreads one Pod per schedulable node. cache uses maxSurge 0 so that a
# rollout under required anti-affinity never needs a third free node.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: cache-tier
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web, tier: frontend}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: {app: web}
              topologyKey: kubernetes.io/hostname
      containers:
        - name: nginx
          image: nginx:1.29
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
  namespace: cache-tier
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 0, maxUnavailable: 1}
  selector:
    matchLabels: {app: cache}
  template:
    metadata:
      labels: {app: cache, tier: cache}
    spec:
      containers:
        - name: cache
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
EOF
wait_deploy cache-tier web 180s || die "ex-wl-03 web이 준비되지 않았습니다."
wait_deploy cache-tier cache 180s || die "ex-wl-03 cache가 준비되지 않았습니다."
