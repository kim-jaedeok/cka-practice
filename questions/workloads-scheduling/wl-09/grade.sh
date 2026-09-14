#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"
grade_init wl-09

wl09_secret_mounted() {
  local volumes volume secret
  volumes="$(_jp_get deploy config-web file-config \
    '{range .spec.template.spec.volumes[*]}{.name}{"|"}{.secret.secretName}{"\n"}{end}')" || return 1
  while IFS='|' read -r volume secret; do
    [ -n "$volume" ] && [ "$secret" = web-config ] || continue
    jp_relation_has deploy config-web file-config \
      '{range .spec.template.spec.containers[?(@.name=="web")].volumeMounts[*]}{.name}{"|"}{.mountPath}{"|"}{.readOnly}{"\n"}{end}' \
      "$volume|/etc/app|true" && return 0
  done <<< "$volumes"
  return 1
}

wl09_file_matches() {
  local expected actual
  expected="$(_jp_get secret web-config file-config '{.data.server\.conf}' | base64 -d)" || return 1
  [ -n "$expected" ] || return 1
  actual="$(kctx -n file-config exec deploy/config-web -c web -- cat /etc/app/server.conf 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

criterion 2 "web-config Secret 볼륨을 web의 /etc/app에 읽기 전용 마운트하고 파일 내용이 일치" \
  "wl09_secret_mounted && wl09_file_matches"
criterion 2 "nginx가 /etc/app/server.conf를 -c로 지정하여 실행" \
  "container_process_is deploy config-web file-config web nginx:1.29 nginx -c /etc/app/server.conf -g 'daemon off;'"
criterion 1 "Deployment 롤아웃 성공 (1/1 Ready)" \
  "deploy_ready file-config config-web 1"
criterion 1 "설정 파일의 응답을 실제 Service에서 확인" \
  "http_body_contains http://config-web.file-config.svc.cluster.local:8080 '^secret-file-ready$'"
grade_finish
