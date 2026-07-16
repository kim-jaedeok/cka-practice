#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-05

criterion 2 "kubelet 서비스가 active 상태" \
  "[ \"\$(node_exec_out cka-worker2 'systemctl is-active kubelet')\" = active ]"

criterion 1 "kubelet 서비스가 enabled (재부팅 대비)" \
  "[ \"\$(node_exec_out cka-worker2 'systemctl is-enabled kubelet')\" = enabled ]"

criterion 4 "노드 cka-worker2가 Ready" \
  "jp_eq node cka-worker2 - '{.status.conditions[?(@.type==\"Ready\")].status}' True"

grade_finish
