#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-06

criterion 1 "ConfigMap app-config 데이터 (DB_HOST, LOG_LEVEL)" \
  "jp_eq cm app-config dept-z '{.data.DB_HOST}' db.example.com && \
   jp_eq cm app-config dept-z '{.data.LOG_LEVEL}' warn"

criterion 1 "Secret app-secret에 DB_PASS 저장" \
  "[ \"\$(_jp_get secret app-secret dept-z '{.data.DB_PASS}' | base64 -d)\" = 'S3cretPass!' ]"

criterion 2 "PriorityClass high-priority (value 100000, globalDefault 아님)" \
  "jp_eq priorityclass high-priority - '{.value}' 100000 && \
   [ \"\$(_jp_get priorityclass high-priority - '{.globalDefault}')\" != 'true' ]"

criterion 1 "Deployment가 priorityClassName: high-priority 사용" \
  "jp_eq deploy config-app dept-z '{.spec.template.spec.priorityClassName}' high-priority"

criterion 2 "컨테이너 환경변수에 ConfigMap 값 주입됨 (실측: printenv)" \
  "[ \"\$(kctx -n dept-z exec deploy/config-app -- printenv DB_HOST 2>/dev/null)\" = db.example.com ] && \
   [ \"\$(kctx -n dept-z exec deploy/config-app -- printenv LOG_LEVEL 2>/dev/null)\" = warn ]"

criterion 1 "컨테이너 환경변수에 Secret 값 주입됨 (실측: printenv)" \
  "[ \"\$(kctx -n dept-z exec deploy/config-app -- printenv DB_PASS 2>/dev/null)\" = 'S3cretPass!' ]"

grade_finish
