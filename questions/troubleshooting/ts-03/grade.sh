#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-03

criterion 1 "Service selector가 Pod 라벨(app=web-app)과 일치" \
  "jp_eq svc web-svc production '{.spec.selector.app}' web-app"

criterion 2 "Service에 엔드포인트 3개 존재" \
  "[ \"\$(kctx -n production get endpointslices -l kubernetes.io/service-name=web-svc -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null | wc -w)\" -ge 3 ]"

criterion 1 "Deployment는 수정되지 않음 (3/3 Ready, 라벨 유지)" \
  "deploy_ready production web-app 3 && \
   jp_eq deploy web-app production '{.spec.selector.matchLabels.app}' web-app"

criterion 2 "실측: web-svc HTTP 접근 성공" \
  "http_ok http://web-svc.production.svc.cluster.local"

grade_finish
