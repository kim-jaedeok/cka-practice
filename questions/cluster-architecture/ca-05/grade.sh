#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-05

criterion 2 "cka-worker가 unschedulable (cordoned)" \
  "jp_eq node cka-worker - '{.spec.unschedulable}' true"

criterion 2 "cka-worker에 DaemonSet 외 Pod 없음 (drain 완료)" \
  "node_drained cka-worker"

criterion 1 "maintenance-app 4개 replica 모두 Ready (무중단 이동)" \
  "deploy_ready upkeep maintenance-app 4"

grade_finish
