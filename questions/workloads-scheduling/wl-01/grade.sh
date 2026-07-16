#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-01

criterion 3 "이미지가 이전 정상 버전(nginx:1.28)으로 롤백됨" \
  "jp_eq deploy api-server dept-x '{.spec.template.spec.containers[0].image}' nginx:1.28"

criterion 1 "replicas가 4로 설정됨" \
  "jp_eq deploy api-server dept-x '{.spec.replicas}' 4"

criterion 3 "4개 replica 모두 Ready" \
  "deploy_ready dept-x api-server 4"

grade_finish
