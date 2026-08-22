#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
# (매니페스트의 오타 kube-schedulerx → kube-scheduler 수정)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

old_container_id="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
  -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
docker exec cka-control-plane sed -i 's|- kube-schedulerx|- kube-scheduler|' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# 기존 Ready mirror 상태를 재사용하지 않고, 수정된 manifest로 새 컨테이너가
# 실제 기동해 Ready가 될 때까지 기다린다.
recovered=0
for i in $(seq 1 60); do
  new_container_id="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
  ready="$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "$ready" = True ] && [ -n "$new_container_id" ] \
      && [ "$new_container_id" != "$old_container_id" ]; then
    recovered=1
    break
  fi
  sleep 2
done
[ "$recovered" -eq 1 ] || die "새 kube-scheduler 컨테이너가 Ready가 되지 않았습니다."

wait_deploy sched-check sched-test 180s
