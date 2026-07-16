#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-05

criterion 1 "ssd-app에 nodeSelector disktype=ssd 설정" \
  "jp_eq deploy ssd-app scheduling '{.spec.template.spec.nodeSelector.disktype}' ssd"

criterion 2 "ssd-app 2개 Pod 모두 cka-worker(ssd 노드)에서 Running" \
  "deploy_ready scheduling ssd-app 2 && \
   [ \"\$(kctx -n scheduling get pods -l app=ssd-app -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | grep -cx cka-worker)\" = 2 ]"

criterion 2 "prod-pod에 toleration(env=prod:NoSchedule) 설정" \
  "jp_contains pod prod-pod scheduling '{.spec.tolerations[?(@.key==\"env\")].value}' prod && \
   jp_contains pod prod-pod scheduling '{.spec.tolerations[?(@.key==\"env\")].effect}' NoSchedule"

criterion 2 "prod-pod가 taint된 cka-worker2에서 Running" \
  "pod_ready scheduling prod-pod && \
   jp_eq pod prod-pod scheduling '{.spec.nodeName}' cka-worker2"

grade_finish
