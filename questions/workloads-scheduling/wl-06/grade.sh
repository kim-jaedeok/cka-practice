#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-06

criterion 1 "ConfigMap app-config 데이터 (DB_HOST, LOG_LEVEL)" \
  "jp_eq cm app-config dept-z '{.data.DB_HOST}' db.example.com && \
   jp_eq cm app-config dept-z '{.data.LOG_LEVEL}' warn"

criterion 1 "Secret app-secret에 DB_PASS 저장" \
  "jp_eq secret app-secret dept-z '{.type}' Opaque && \
   [ \"\$(_jp_get secret app-secret dept-z '{.data.DB_PASS}' | base64 -d)\" = 'S3cretPass!' ]"

criterion 2 "PriorityClass high-priority (value 100000, globalDefault 아님)" \
  "jp_eq priorityclass high-priority - '{.value}' 100000 && \
   [ \"\$(_jp_get priorityclass high-priority - '{.globalDefault}')\" != 'true' ]"

criterion 1 "Deployment의 replica, app 이미지/명령, PriorityClass 스펙" \
  "jp_eq deploy config-app dept-z '{.spec.replicas}' 1 && \
   jp_eq deploy config-app dept-z '{.spec.template.spec.priorityClassName}' high-priority && \
   container_process_is deploy config-app dept-z app busybox:1.36 sleep infinity"

criterion 2 "app 컨테이너가 ConfigMap 전체를 envFrom으로 참조하고 값이 주입됨" \
  "jp_relation_has deploy config-app dept-z \
     '{range .spec.template.spec.containers[?(@.name==\"app\")].envFrom[*]}{.configMapRef.name}{\"|\"}{.prefix}{\"\\n\"}{end}' \
     'app-config|' && \
   [ \"\$(kctx -n dept-z exec deploy/config-app -c app -- printenv DB_HOST 2>/dev/null)\" = db.example.com ] && \
   [ \"\$(kctx -n dept-z exec deploy/config-app -c app -- printenv LOG_LEVEL 2>/dev/null)\" = warn ]"

criterion 1 "app 컨테이너가 Secret key를 valueFrom으로 참조하고 값이 주입됨" \
  "jp_relation_has deploy config-app dept-z \
     '{range .spec.template.spec.containers[?(@.name==\"app\")].env[*]}{.name}{\"|\"}{.valueFrom.secretKeyRef.name}{\"|\"}{.valueFrom.secretKeyRef.key}{\"\\n\"}{end}' \
     'DB_PASS|app-secret|DB_PASS' && \
   [ \"\$(kctx -n dept-z exec deploy/config-app -c app -- printenv DB_PASS 2>/dev/null)\" = 'S3cretPass!' ]"

grade_finish
