#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-01

criterion 2 "이미지가 nginx:1.29로 수정됨" \
  "jp_eq deploy frontend app-track '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 3 "3개 replica 모두 Ready" \
  "deploy_ready app-track frontend 3"

grade_finish
