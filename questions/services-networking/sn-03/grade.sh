#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-03

criterion 2 "default-deny-ingress: 모든 Pod 대상 Ingress 차단 정책" \
  "res_exists netpol default-deny-ingress secure-apps && \
   [ -z \"\$(_jp_get netpol default-deny-ingress secure-apps '{.spec.podSelector.matchLabels}')\" ] && \
   jp_contains netpol default-deny-ingress secure-apps '{.spec.policyTypes[*]}' Ingress"

criterion 2 "allow-backend-to-db: role=db 대상, role=backend 발신, TCP 80 허용" \
  "jp_eq netpol allow-backend-to-db secure-apps '{.spec.podSelector.matchLabels.role}' db && \
   jp_contains netpol allow-backend-to-db secure-apps '{.spec.ingress[0].from[*].podSelector.matchLabels.role}' backend && \
   jp_contains netpol allow-backend-to-db secure-apps '{.spec.ingress[0].ports[*].port}' 80"

criterion 2 "실측: backend → db 접근 성공" \
  "http_ok_from secure-apps backend http://db-svc.secure-apps.svc.cluster.local"

criterion 2 "실측: other → db 접근 차단" \
  "http_denied_from secure-apps other http://db-svc.secure-apps.svc.cluster.local"

grade_finish
