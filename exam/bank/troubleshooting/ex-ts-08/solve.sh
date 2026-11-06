#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

stuck="$(kctx -n nightly-ops get cronjob db-vacuum -o jsonpath='{.status.active[0].name}')"
kctx -n nightly-ops patch cronjob db-vacuum --type=merge \
  -p '{"spec":{"jobTemplate":{"spec":{"activeDeadlineSeconds":120}}}}' >/dev/null
kctx -n nightly-ops delete job "$stuck" --wait=true >/dev/null
kctx -n nightly-ops create job --from=cronjob/db-vacuum db-vacuum-manual >/dev/null
kctx -n nightly-ops wait --for=condition=Complete job/db-vacuum-manual --timeout=120s >/dev/null
