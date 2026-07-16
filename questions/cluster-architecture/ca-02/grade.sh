#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-02

criterion 2 "ClusterRole node-viewer: nodes에 get/list" \
  "jp_contains clusterrole node-viewer - '{.rules[0].resources[*]}' nodes && \
   jp_contains clusterrole node-viewer - '{.rules[0].verbs[*]}' get && \
   jp_contains clusterrole node-viewer - '{.rules[0].verbs[*]}' list"

criterion 1 "ClusterRoleBinding이 ClusterRole과 SA를 연결" \
  "jp_eq clusterrolebinding node-viewer-binding - '{.roleRef.name}' node-viewer && \
   jp_contains clusterrolebinding node-viewer-binding - '{.subjects[*].name}' node-inspector"

criterion 1 "실측: SA가 nodes list 가능" \
  "can_i list nodes default system:serviceaccount:dev-team:node-inspector"

criterion 1 "실측: nodes delete 불가" \
  "cannot_i delete nodes default system:serviceaccount:dev-team:node-inspector"

criterion 1 "실측: secrets list 불가" \
  "cannot_i list secrets default system:serviceaccount:dev-team:node-inspector"

grade_finish
