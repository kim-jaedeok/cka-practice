#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-11

criterion 1 "ingressClassName: nginx 지정" \
  "jp_eq ingress shop-ingress shop '{.spec.ingressClassName}' nginx"

criterion 2 "backend가 checkout-svc:80으로 수정됨" \
  "jp_eq ingress shop-ingress shop '{.spec.rules[0].http.paths[0].backend.service.name}' checkout-svc && \
   jp_eq ingress shop-ingress shop '{.spec.rules[0].http.paths[0].backend.service.port.number}' 80"

criterion 3 "실측: Ingress 경유 접근 성공" \
  "ingress_ok shop.example.com / 'checkout service ready'"

grade_finish
