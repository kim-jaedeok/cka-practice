#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n ledger create serviceaccount audit-sa
# The ReplicaSet controller retries failed creates with exponential backoff.
# A restart creates a fresh ReplicaSet so the fix takes effect at once.
kctx -n ledger rollout restart deploy/audit-writer >/dev/null
wait_deploy ledger audit-writer 180s
