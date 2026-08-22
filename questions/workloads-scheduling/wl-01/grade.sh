#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-01

wl01_deployment_uid_preserved() {
  local baseline current path="$CKA_STATE_DIR/question-data/wl-01/baseline-deployment-uid"
  [ -s "$path" ] || { grade_invalid "wl-01 baseline Deployment UID missing" || true; return 2; }
  baseline="$(tr -d '\r\n' < "$path")"
  current="$(kctx -n dept-x get deploy api-server -o jsonpath='{.metadata.uid}' 2>/dev/null)" \
    || return 1
  [ -n "$baseline" ] && [ "$current" = "$baseline" ]
}

criterion 3 "기존 Deployment를 보존하고 nginx:1.28 상태로 롤백" \
  "wl01_deployment_uid_preserved && \
   jp_relation_has deploy api-server dept-x \
     '{range .spec.template.spec.containers[*]}{.name}{\"|\"}{.image}{\"\\n\"}{end}' \
     'api|nginx:1.28'"

criterion 1 "replicas가 4로 설정됨" \
  "jp_eq deploy api-server dept-x '{.spec.replicas}' 4"

criterion 3 "4개 replica 모두 Ready" \
  "deploy_ready dept-x api-server 4"

grade_finish
