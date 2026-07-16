#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-02

criterion 2 "Service asia-svc: NodePort 30080, port 80 → 80" \
  "jp_eq svc asia-svc world '{.spec.type}' NodePort && \
   jp_eq svc asia-svc world '{.spec.ports[0].nodePort}' 30080 && \
   jp_eq svc asia-svc world '{.spec.ports[0].port}' 80 && \
   jp_eq svc asia-svc world '{.spec.ports[0].targetPort}' 80"

criterion 1 "Service에 엔드포인트 존재" \
  "svc_has_endpoints world asia-svc"

criterion 2 "노드 IP:30080 으로 HTTP 접근 성공 (실측)" \
  "http_ok \"http://\$(kctx get node cka-worker -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'):30080\""

grade_finish
