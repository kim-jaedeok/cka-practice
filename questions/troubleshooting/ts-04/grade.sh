#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-04

criterion 2 "requests가 64Mi / 50m 로 수정됨" \
  "jp_eq deploy bigmem heavy '{.spec.template.spec.containers[0].resources.requests.memory}' 64Mi && \
   jp_eq deploy bigmem heavy '{.spec.template.spec.containers[0].resources.requests.cpu}' 50m"

criterion 1 "limits가 128Mi / 200m 로 설정됨" \
  "jp_eq deploy bigmem heavy '{.spec.template.spec.containers[0].resources.limits.memory}' 128Mi && \
   jp_eq deploy bigmem heavy '{.spec.template.spec.containers[0].resources.limits.cpu}' 200m"

criterion 3 "2개 replica 모두 Ready (Pending 해소)" \
  "deploy_ready heavy bigmem 2"

grade_finish
