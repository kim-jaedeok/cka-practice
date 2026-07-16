#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-01

criterion 2 "Service europe-svc: ClusterIP, port 80 → targetPort 80" \
  "jp_eq svc europe-svc world '{.spec.type}' ClusterIP && \
   jp_eq svc europe-svc world '{.spec.ports[0].port}' 80 && \
   jp_eq svc europe-svc world '{.spec.ports[0].targetPort}' 80"

criterion 1 "Service에 엔드포인트 존재 (selector가 Pod와 매칭)" \
  "svc_has_endpoints world europe-svc"

criterion 2 "클러스터 내부에서 HTTP 접근 성공 (실측)" \
  "http_ok http://europe-svc.world.svc.cluster.local"

grade_finish
