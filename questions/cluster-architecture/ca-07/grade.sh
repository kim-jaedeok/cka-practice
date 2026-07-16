#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-07

criterion 2 "Helm release webapp-rel이 helm-apps에 deployed 상태" \
  "helm -n helm-apps status webapp-rel --kube-context \"\$CKA_CONTEXT\" 2>/dev/null | grep -q 'STATUS: deployed'"

criterion 1 "release revision 2 이상 (upgrade 수행됨)" \
  "[ \"\$(helm -n helm-apps list --kube-context \"\$CKA_CONTEXT\" -f webapp-rel -o json 2>/dev/null | grep -o '\"revision\":\"[0-9]*\"' | grep -o '[0-9]*')\" -ge 2 ]"

criterion 2 "Deployment webapp-rel 이미지가 nginx:1.29" \
  "jp_eq deploy webapp-rel helm-apps '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 2 "replicas 2개 모두 Ready" \
  "deploy_ready helm-apps webapp-rel 2"

grade_finish
