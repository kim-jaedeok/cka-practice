#!/usr/bin/env bash
# kube-scheduler 매니페스트를 원본으로 복원한다
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

BACKUP="$CKA_STATE_DIR/backup/kube-scheduler.yaml"
[ -f "$BACKUP" ] || exit 0
docker exec -i cka-control-plane sh -c 'cat > /etc/kubernetes/manifests/kube-scheduler.yaml' \
  < "$BACKUP"
# 스케줄러가 돌아올 때까지 대기
for i in $(seq 1 30); do
  [ "$(kctx -n kube-system get pod kube-scheduler-cka-control-plane \
      -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 3
done
