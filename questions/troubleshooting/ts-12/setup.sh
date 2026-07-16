#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=ts-12
require_cluster
cleanup_question "$QID"

# 원본 kube-scheduler 매니페스트 백업 (최초 1회)
mkdir -p "$CKA_STATE_DIR/backup"
if [ ! -f "$CKA_STATE_DIR/backup/kube-scheduler.yaml" ]; then
  docker exec cka-control-plane cat /etc/kubernetes/manifests/kube-scheduler.yaml \
    > "$CKA_STATE_DIR/backup/kube-scheduler.yaml"
fi

# 스케줄러 커맨드를 오타로 망가뜨린다
docker exec cka-control-plane sed -i 's|- kube-scheduler|- kube-schedulerx|' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# 스케줄러가 내려간 뒤 테스트 deployment 생성 → Pending 상태가 된다
sleep 10
recreate_ns "$QID" sched-check
kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sched-test
  namespace: sched-check
spec:
  replicas: 2
  selector:
    matchLabels: {app: sched-test}
  template:
    metadata:
      labels: {app: sched-test}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
EOF
info "kube-scheduler가 중단된 상태입니다. sched-test Pod는 Pending으로 남습니다."
