#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-01

criterion 2 "Role pod-reader: pods에 get/list/watch" \
  "rbac_rule_has role pod-reader dev-team '' pods get && \
   rbac_rule_has role pod-reader dev-team '' pods list && \
   rbac_rule_has role pod-reader dev-team '' pods watch"

criterion 1 "RoleBinding이 Role과 SA를 올바르게 연결" \
  "jp_eq rolebinding app-reader-binding dev-team '{.roleRef.apiGroup}' rbac.authorization.k8s.io && \
   jp_eq rolebinding app-reader-binding dev-team '{.roleRef.kind}' Role && \
   jp_eq rolebinding app-reader-binding dev-team '{.roleRef.name}' pod-reader && \
   jp_relation_has rolebinding app-reader-binding dev-team \
     '{range .subjects[*]}{.kind}{\"|\"}{.namespace}{\"|\"}{.name}{\"\\n\"}{end}' \
     'ServiceAccount|dev-team|app-reader'"

criterion 1 "실측: SA가 dev-team에서 pods get/list/watch 가능" \
  "can_i get pods dev-team system:serviceaccount:dev-team:app-reader && \
   can_i list pods dev-team system:serviceaccount:dev-team:app-reader && \
   can_i watch pods dev-team system:serviceaccount:dev-team:app-reader"

criterion 1 "실측: SA가 pods delete는 불가" \
  "cannot_i delete pods dev-team system:serviceaccount:dev-team:app-reader"

criterion 1 "실측: 다른 네임스페이스(default)에서는 Pod 읽기 불가" \
  "cannot_i get pods default system:serviceaccount:dev-team:app-reader && \
   cannot_i list pods default system:serviceaccount:dev-team:app-reader && \
   cannot_i watch pods default system:serviceaccount:dev-team:app-reader"

grade_finish
