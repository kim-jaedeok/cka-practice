#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-08

criterion 2 "Deployment prod-kapp이 kust-prod 네임스페이스에 존재" \
  "res_exists deploy prod-kapp kust-prod"

criterion 1 "Service prod-kapp 존재" \
  "res_exists svc prod-kapp kust-prod"

criterion 1 "이미지 태그가 overlay대로 nginx:1.29" \
  "jp_eq deploy prod-kapp kust-prod '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 2 "3개 replica 모두 Ready" \
  "deploy_ready kust-prod prod-kapp 3"

grade_finish
