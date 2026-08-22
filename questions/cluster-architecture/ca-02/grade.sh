#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-02

criterion 2 "ClusterRole node-viewer: nodes에 get/list" \
  "rbac_rule_has clusterrole node-viewer - '' nodes get && \
   rbac_rule_has clusterrole node-viewer - '' nodes list"

criterion 1 "ClusterRoleBinding이 ClusterRole과 SA를 연결" \
  "jp_eq clusterrolebinding node-viewer-binding - '{.roleRef.apiGroup}' rbac.authorization.k8s.io && \
   jp_eq clusterrolebinding node-viewer-binding - '{.roleRef.kind}' ClusterRole && \
   jp_eq clusterrolebinding node-viewer-binding - '{.roleRef.name}' node-viewer && \
   jp_relation_has clusterrolebinding node-viewer-binding - \
     '{range .subjects[*]}{.kind}{\"|\"}{.namespace}{\"|\"}{.name}{\"\\n\"}{end}' \
     'ServiceAccount|dev-team|node-inspector'"

criterion 1 "실측: SA가 nodes get/list 가능" \
  "can_i get nodes default system:serviceaccount:dev-team:node-inspector && \
   can_i list nodes default system:serviceaccount:dev-team:node-inspector"

criterion 1 "실측: nodes delete 불가" \
  "cannot_i delete nodes default system:serviceaccount:dev-team:node-inspector"

criterion 1 "실측: secrets list 불가" \
  "cannot_i list secrets default system:serviceaccount:dev-team:node-inspector"

grade_finish
