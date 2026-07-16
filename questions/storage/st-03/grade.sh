#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-03

criterion 3 "PVC cache-pvc의 요청 용량이 3Gi로 확장됨" \
  "jp_eq pvc cache-pvc project-gamma '{.spec.resources.requests.storage}' 3Gi"

criterion 1 "Pod cache-pod가 여전히 Running (삭제/재생성 금지 준수)" \
  "pod_ready project-gamma cache-pod"

grade_finish
