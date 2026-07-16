#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-01

criterion 2 "Role pod-reader: pods에 get/list/watch" \
  "jp_contains role pod-reader dev-team '{.rules[0].resources[*]}' pods && \
   jp_contains role pod-reader dev-team '{.rules[0].verbs[*]}' get && \
   jp_contains role pod-reader dev-team '{.rules[0].verbs[*]}' list && \
   jp_contains role pod-reader dev-team '{.rules[0].verbs[*]}' watch"

criterion 1 "RoleBinding이 Role과 SA를 올바르게 연결" \
  "jp_eq rolebinding app-reader-binding dev-team '{.roleRef.name}' pod-reader && \
   jp_contains rolebinding app-reader-binding dev-team '{.subjects[*].name}' app-reader"

criterion 1 "실측: SA가 dev-team에서 pods list 가능" \
  "can_i list pods dev-team system:serviceaccount:dev-team:app-reader"

criterion 1 "실측: SA가 pods delete는 불가" \
  "cannot_i delete pods dev-team system:serviceaccount:dev-team:app-reader"

criterion 1 "실측: 다른 네임스페이스(default)에서는 list 불가" \
  "cannot_i list pods default system:serviceaccount:dev-team:app-reader"

grade_finish
