#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-12

ts12_scheduler_ready() {
  local attempt
  node_exec cka-control-plane \
    'grep -q "^    - kube-scheduler$" /etc/kubernetes/manifests/kube-scheduler.yaml' \
    || return 1
  for attempt in $(seq 1 30); do
    if container_argv_has pod kube-scheduler-cka-control-plane kube-system \
        kube-scheduler kube-scheduler \
        && pod_ready kube-system kube-scheduler-cka-control-plane; then
      return 0
    fi
    sleep 1
  done
  return 1
}

criterion 2 "kube-scheduler 매니페스트의 오타가 수정됨" \
  "node_exec cka-control-plane 'grep -q \"^    - kube-scheduler$\" /etc/kubernetes/manifests/kube-scheduler.yaml'"

criterion 3 "kube-scheduler Pod가 Running/Ready" \
  "ts12_scheduler_ready"

criterion 3 "sched-test 2개 replica 모두 Ready (스케줄링 정상화)" \
  "deploy_ready sched-check sched-test 2"

grade_finish
