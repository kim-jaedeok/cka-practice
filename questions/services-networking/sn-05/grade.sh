#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-05

criterion 2 "Gateway main-gw: class nginx, listener http/HTTP/80" \
  "jp_eq gateway main-gw traffic '{.spec.gatewayClassName}' nginx && \
   jp_eq gateway main-gw traffic '{.spec.listeners[0].name}' http && \
   jp_eq gateway main-gw traffic '{.spec.listeners[0].protocol}' HTTP && \
   jp_eq gateway main-gw traffic '{.spec.listeners[0].port}' 80"

criterion 1 "Gateway listener hostname: shop.example.com" \
  "jp_eq gateway main-gw traffic '{.spec.listeners[0].hostname}' shop.example.com"

criterion 2 "HTTPRoute store-route: main-gw에 연결 + hostname 일치" \
  "jp_contains httproute store-route traffic '{.spec.parentRefs[*].name}' main-gw && \
   jp_contains httproute store-route traffic '{.spec.hostnames[*]}' shop.example.com"

criterion 1 "HTTPRoute 규칙: /store PathPrefix → store-svc:80" \
  "jp_eq httproute store-route traffic '{.spec.rules[0].matches[0].path.type}' PathPrefix && \
   jp_eq httproute store-route traffic '{.spec.rules[0].matches[0].path.value}' /store && \
   jp_eq httproute store-route traffic '{.spec.rules[0].backendRefs[0].name}' store-svc && \
   jp_eq httproute store-route traffic '{.spec.rules[0].backendRefs[0].port}' 80"

grade_finish
