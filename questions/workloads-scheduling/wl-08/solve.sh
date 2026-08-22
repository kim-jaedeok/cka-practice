#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 절차
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

# 기존 두 Pod의 600m request가 새 Pod admission을 계속 막으므로 먼저 비운다.
kctx -n admission-guard scale deploy/quota-web --replicas=0 >/dev/null
kctx -n admission-guard wait --for=delete pod -l app=quota-web --timeout=90s \
  >/dev/null 2>&1 || true

kctx -n admission-guard set resources deploy/quota-web -c nginx \
  --requests=cpu=200m,memory=128Mi \
  --limits=cpu=400m,memory=256Mi >/dev/null
kctx -n admission-guard scale deploy/quota-web --replicas=3 >/dev/null

wait_deploy admission-guard quota-web 180s

# ResourceQuota status controller의 관측값이 채점 전에 수렴하도록 기다린다.
for _ in $(seq 1 30); do
  [ "$(kctx -n admission-guard get resourcequota team-budget \
      -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null)" = 600m ] && break
  sleep 1
done
