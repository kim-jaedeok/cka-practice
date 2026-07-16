#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-04

criterion 2 "PVC store-data 볼륨이 /var/www/data에 마운트됨" \
  "jp_contains deploy web-store project-delta '{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}' store-data && \
   jp_contains deploy web-store project-delta '{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' /var/www/data"

criterion 2 "emptyDir 볼륨 tmp-cache가 /tmp/cache에 마운트됨" \
  "jp_contains deploy web-store project-delta '{.spec.template.spec.volumes[?(@.name==\"tmp-cache\")]}' emptyDir && \
   jp_contains deploy web-store project-delta '{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' /tmp/cache"

criterion 1 "Deployment가 정상 롤아웃됨 (1/1 Ready)" \
  "deploy_ready project-delta web-store 1"

grade_finish
