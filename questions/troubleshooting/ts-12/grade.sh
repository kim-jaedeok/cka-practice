#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-12

criterion 2 "kube-scheduler 매니페스트의 오타가 수정됨" \
  "node_exec cka-control-plane 'grep -q \"^    - kube-scheduler$\" /etc/kubernetes/manifests/kube-scheduler.yaml'"

criterion 3 "kube-scheduler Pod가 Running/Ready" \
  "pod_ready kube-system kube-scheduler-cka-control-plane"

criterion 3 "sched-test 2개 replica 모두 Ready (스케줄링 정상화)" \
  "deploy_ready sched-check sched-test 2"

grade_finish
