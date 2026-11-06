#!/usr/bin/env bash
# Near-miss fixture: the hanging Job is removed and a new run completes, but
# the CronJob still has no deadline, so the next hang blocks it again.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

stuck="$(kctx -n nightly-ops get cronjob db-vacuum -o jsonpath='{.status.active[0].name}')"
kctx -n nightly-ops delete job "$stuck" --wait=true >/dev/null
kctx -n nightly-ops create job --from=cronjob/db-vacuum db-vacuum-manual >/dev/null
kctx -n nightly-ops wait --for=condition=Complete job/db-vacuum-manual --timeout=120s >/dev/null
