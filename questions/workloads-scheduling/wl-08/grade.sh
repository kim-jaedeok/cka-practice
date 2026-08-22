#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-08

criterion 2 "LimitRange guardrails가 요구된 container 경계를 유지" \
  "jp_relation_has limitrange guardrails admission-guard \
   '{range .spec.limits[?(@.type==\"Container\")]}{.min.cpu}{\"|\"}{.min.memory}{\"|\"}{.max.cpu}{\"|\"}{.max.memory}{\"|\"}{.defaultRequest.cpu}{\"|\"}{.defaultRequest.memory}{\"|\"}{.default.cpu}{\"|\"}{.default.memory}{\"\\n\"}{end}' \
   '100m|64Mi|500m|256Mi|200m|128Mi|400m|256Mi'"

criterion 1 "ResourceQuota team-budget의 hard limit가 유지" \
  "jp_eq resourcequota team-budget admission-guard '{.spec.hard.pods}' 3 && \
   jp_eq resourcequota team-budget admission-guard '{.spec.hard.requests\\.cpu}' 600m && \
   jp_eq resourcequota team-budget admission-guard '{.spec.hard.requests\\.memory}' 384Mi && \
   jp_eq resourcequota team-budget admission-guard '{.spec.hard.limits\\.cpu}' 1200m && \
   jp_eq resourcequota team-budget admission-guard '{.spec.hard.limits\\.memory}' 768Mi && \
   jp_eq resourcequota team-budget admission-guard '{.spec.scopes}' '' && \
   jp_eq resourcequota team-budget admission-guard '{.spec.scopeSelector}' ''"

criterion 2 "quota-web nginx image와 requests/limits가 정확" \
  "jp_relation_has deploy quota-web admission-guard \
   '{range .spec.template.spec.containers[*]}{.name}{\"|\"}{.image}{\"|\"}{.resources.requests.cpu}{\"|\"}{.resources.requests.memory}{\"|\"}{.resources.limits.cpu}{\"|\"}{.resources.limits.memory}{\"\\n\"}{end}' \
   'nginx|nginx:1.29|200m|128Mi|400m|256Mi'"

criterion 2 "quota-web가 3/3 Ready" \
  "jp_eq deploy quota-web admission-guard '{.spec.replicas}' 3 && \
   deploy_ready admission-guard quota-web 3"

criterion 1 "관측된 quota 사용량이 세 Pod와 600m request를 반영" \
  "jp_eq resourcequota team-budget admission-guard '{.status.used.pods}' 3 && \
   jp_eq resourcequota team-budget admission-guard '{.status.used.requests\\.cpu}' 600m"

grade_finish
