#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-sn-02

EXSN02_CONTROLLER=http://ingress-nginx-controller.ingress-nginx.svc.cluster.local

# exsn02_routes <host> <path> <expected body substring>
exsn02_routes() {
  _grader_client_require || return $?
  _dns_baseline_grader || return $?
  kctx -n cka-system exec deploy/grader-client -- \
    wget -q -O - -T 4 --header "Host: $1" "$EXSN02_CONTROLLER$2" 2>/dev/null \
    | grep -Fq -- "$3"
}

criterion 1 "Ingress portal uses IngressClass nginx" \
  "jp_eq ingress portal docs-portal '{.spec.ingressClassName}' nginx"

criterion 2 "실측: docs.portal.test/ reaches docs-v2" \
  "exsn02_routes docs.portal.test / 'docs portal v2'"

criterion 1 "실측: legacy.portal.test/ reaches docs-v1" \
  "exsn02_routes legacy.portal.test / 'docs portal v1'"

criterion 2 "실측: /status (Exact) reaches status-page and /status/history reaches docs-v2" \
  "exsn02_routes docs.portal.test /status 'all systems operational' && \
   exsn02_routes docs.portal.test /status/history 'docs portal v2'"

grade_finish
