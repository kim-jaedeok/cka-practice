#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-10

criterion 2 "Role 규칙: apps 그룹의 deployments에 get/list/update" \
  "jp_contains role deployer-role ci-cd '{.rules[*].apiGroups[*]}' apps && \
   jp_contains role deployer-role ci-cd '{.rules[*].resources[*]}' deployments && \
   jp_contains role deployer-role ci-cd '{.rules[*].verbs[*]}' update"

criterion 2 "실측: SA가 deployments list/update 가능" \
  "can_i list deployments ci-cd system:serviceaccount:ci-cd:deployer && \
   can_i update deployments ci-cd system:serviceaccount:ci-cd:deployer"

criterion 2 "실측: deployments delete는 불가" \
  "cannot_i delete deployments ci-cd system:serviceaccount:ci-cd:deployer"

grade_finish
