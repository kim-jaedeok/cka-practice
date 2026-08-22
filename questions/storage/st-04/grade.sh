#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-04

criterion 2 "PVC store-data 볼륨이 /var/www/data에 마운트됨" \
  "claim_mounted_at deploy web-store project-delta store-data /var/www/data nginx"

criterion 2 "emptyDir 볼륨 tmp-cache가 /tmp/cache에 마운트됨" \
  "emptydir_mounted_at deploy web-store project-delta tmp-cache /tmp/cache nginx"

criterion 1 "Deployment가 정상 롤아웃됨 (1/1 Ready)" \
  "deploy_ready project-delta web-store 1"

grade_finish
