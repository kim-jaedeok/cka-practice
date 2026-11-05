#!/usr/bin/env bash
# Near-miss fixture: the Job is fixed, but the error line was not saved before
# the failed Pods were deleted together with the old Job.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx -n reports get job nightly-report -o json | python3 -c '
import json, sys
job = json.load(sys.stdin)
meta = job["metadata"]
job["metadata"] = {"name": meta["name"], "namespace": meta["namespace"]}
job.pop("status", None)
spec = job["spec"]
spec.pop("selector", None)
spec["template"]["metadata"] = {}
spec["template"]["spec"]["containers"][0]["volumeMounts"][0]["mountPath"] = "/etc/report"
print(json.dumps(job))
' > "${TMPDIR:-/tmp}/ex-ts-03-job.json"
kctx -n reports delete job nightly-report --wait=true >/dev/null
kctx apply -f "${TMPDIR:-/tmp}/ex-ts-03-job.json" >/dev/null
rm -f "${TMPDIR:-/tmp}/ex-ts-03-job.json"
kctx -n reports wait --for=condition=Complete job/nightly-report --timeout=120s >/dev/null
