#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-07

criterion 2 "Service targetPort가 컨테이너 포트(80)로 수정됨" \
  "jp_eq svc payments-svc commerce '{.spec.ports[0].targetPort}' 80"

criterion 1 "Deployment는 수정되지 않음 (containerPort 80, 2 replicas 유지)" \
  "jp_eq deploy payments commerce '{.spec.template.spec.containers[0].ports[0].containerPort}' 80 && \
   deploy_ready commerce payments 2"

criterion 2 "실측: payments-svc HTTP 접근 성공" \
  "http_ok http://payments-svc.commerce.svc.cluster.local"

grade_finish
