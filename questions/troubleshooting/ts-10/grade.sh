#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-10

criterion 2 "Role 규칙: apps 그룹의 deployments에 get/list/update" \
  "rbac_rule_has role deployer-role ci-cd apps deployments get && \
   rbac_rule_has role deployer-role ci-cd apps deployments list && \
   rbac_rule_has role deployer-role ci-cd apps deployments update"

criterion 2 "실측: SA가 deployments get/list/update 가능" \
  "can_i get deployments ci-cd system:serviceaccount:ci-cd:deployer && \
   can_i list deployments ci-cd system:serviceaccount:ci-cd:deployer && \
   can_i update deployments ci-cd system:serviceaccount:ci-cd:deployer"

criterion 2 "실측: deployments delete는 불가" \
  "cannot_i delete deployments ci-cd system:serviceaccount:ci-cd:deployer"

grade_finish
