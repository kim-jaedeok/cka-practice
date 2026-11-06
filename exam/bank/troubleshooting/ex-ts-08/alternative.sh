#!/usr/bin/env bash
# Alternative fixture: instead of deleting the hanging Job, give it a deadline
# so the Job controller fails it. The CronJob then starts its next run on its
# own schedule. No manual Job is created.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

stuck="$(kctx -n nightly-ops get cronjob db-vacuum -o jsonpath='{.status.active[0].name}')"
kctx -n nightly-ops patch cronjob db-vacuum --type=merge \
  -p '{"spec":{"jobTemplate":{"spec":{"activeDeadlineSeconds":90}}}}' >/dev/null
kctx -n nightly-ops patch job "$stuck" --type=merge \
  -p '{"spec":{"activeDeadlineSeconds":1}}' >/dev/null
kctx -n nightly-ops wait --for=condition=Failed "job/$stuck" --timeout=60s >/dev/null

# Wait for a scheduled run (at most about one minute) to complete.
for _ in $(seq 1 50); do
  done_jobs="$(kctx -n nightly-ops get jobs \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.succeeded}{"\n"}{end}' 2>/dev/null \
    | grep -c '|1$' || true)"
  [ "${done_jobs:-0}" -ge 1 ] && exit 0
  sleep 3
done
exit 1
