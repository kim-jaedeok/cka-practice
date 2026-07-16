#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
# (매니페스트의 오타 kube-schedulerx → kube-scheduler 수정)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec cka-control-plane sed -i 's|- kube-schedulerx|- kube-scheduler|' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# 스케줄러 복귀 대기
for i in $(seq 1 40); do
  [ "$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 3
done

wait_deploy sched-check sched-test 180s
