#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-02

criterion 2 "command가 sleep infinity로 수정됨 (exit 1 제거)" \
  "jp_contains deploy worker batch-jobs '{.spec.template.spec.containers[0].command[*]}' sleep && \
   ! jp_contains deploy worker batch-jobs '{.spec.template.spec.containers[0].command[*]}' 'exit 1'"

criterion 3 "2개 replica 모두 Ready" \
  "deploy_ready batch-jobs worker 2"

criterion 1 "CrashLoop 중인 Pod 없음" \
  "! kctx -n batch-jobs get pods -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -q CrashLoopBackOff"

grade_finish
