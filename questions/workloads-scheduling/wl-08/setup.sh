#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=wl-08
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" admission-guard

kctx apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: guardrails
  namespace: admission-guard
spec:
  limits:
    - type: Container
      min:
        cpu: 100m
        memory: 64Mi
      max:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 200m
        memory: 128Mi
      default:
        cpu: 400m
        memory: 256Mi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-budget
  namespace: admission-guard
spec:
  hard:
    pods: "3"
    requests.cpu: 600m
    requests.memory: 384Mi
    limits.cpu: 1200m
    limits.memory: 768Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-web
  namespace: admission-guard
spec:
  replicas: 3
  selector:
    matchLabels:
      app: quota-web
  template:
    metadata:
      labels:
        app: quota-web
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          resources:
            requests:
              cpu: 300m
              memory: 128Mi
            limits:
              cpu: 400m
              memory: 256Mi
EOF

# 출발 상태는 의도적으로 Available이 될 수 없다. 세 번째 Pod의
# 300m request는 이미 생성된 두 Pod가 채운 600m quota에 거부되어야 한다.
# 불가능한 Available wait를 시간만 낭비하게 두지 않고, 출발 계약 세 가지를
# 짧은 polling으로 전부 확인한다.
baseline_ready() {
  [ "$(kctx -n admission-guard get deploy quota-web \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 2 ] &&
  [ "$(kctx -n admission-guard get deploy quota-web \
      -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].status}' \
      2>/dev/null)" = True ] &&
  [ "$(kctx -n admission-guard get resourcequota team-budget \
      -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null)" = 600m ]
}

for _ in $(seq 1 30); do
  baseline_ready && break
  sleep 1
done
baseline_ready \
  || die "wl-08 출발 상태 불일치: 2 Ready / ReplicaFailure / quota 600m를 확인하세요."
