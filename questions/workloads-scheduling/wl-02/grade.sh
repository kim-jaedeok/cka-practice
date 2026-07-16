#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-02

criterion 3 "initContainer logger-con이 restartPolicy: Always로 정의됨 (native sidecar)" \
  "jp_eq deploy cleaner mercury '{.spec.template.spec.initContainers[0].name}' logger-con && \
   jp_eq deploy cleaner mercury '{.spec.template.spec.initContainers[0].restartPolicy}' Always && \
   jp_eq deploy cleaner mercury '{.spec.template.spec.initContainers[0].image}' busybox:1.36"

criterion 2 "logger-con이 logs 볼륨을 /var/log/cleaner에 마운트" \
  "jp_contains deploy cleaner mercury '{.spec.template.spec.initContainers[0].volumeMounts[?(@.name==\"logs\")].mountPath}' /var/log/cleaner"

criterion 1 "Deployment 롤아웃 성공 (1/1 Ready)" \
  "deploy_ready mercury cleaner 1"

criterion 2 "kubectl logs -c logger-con 으로 애플리케이션 로그 확인 가능" \
  "pod=\$(kctx -n mercury get pods -l app=cleaner --sort-by=.metadata.creationTimestamp -o name | tail -1); \
   kctx -n mercury logs \"\$pod\" -c logger-con --tail=5 2>/dev/null | grep -q 'cleaner iteration'"

grade_finish
