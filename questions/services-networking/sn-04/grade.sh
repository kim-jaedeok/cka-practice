#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-04

criterion 2 "Ingress web-ingress 스펙 (class nginx, host, 2개 path 라우팅)" \
  "jp_eq ingress web-ingress web-zone '{.spec.ingressClassName}' nginx && \
   jp_eq ingress web-ingress web-zone '{.spec.rules[0].host}' app.example.com && \
   jp_contains ingress web-ingress web-zone '{.spec.rules[0].http.paths[?(@.path==\"/a\")].backend.service.name}' web-a && \
   jp_contains ingress web-ingress web-zone '{.spec.rules[0].http.paths[?(@.path==\"/b\")].backend.service.name}' web-b"

criterion 2 "실측: /a 요청이 web-a로 라우팅됨" \
  "ingress_ok app.example.com /a/ 'response from web-a'"

criterion 2 "실측: /b 요청이 web-b로 라우팅됨" \
  "ingress_ok app.example.com /b/ 'response from web-b'"

grade_finish
