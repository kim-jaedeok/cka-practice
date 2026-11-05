#!/usr/bin/env bash
# Alternative fixture: keep the original mount and add a subPath mount of the
# single key at the exact file path the script reads. The image and command
# stay unchanged, so this earns full credit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ex-ts-03"
kctx -n reports logs job/nightly-report --tail=1 > "$CKA_WORK_DIR/ex-ts-03/job-error.log"

kctx -n reports get job nightly-report -o json | python3 -c '
import json, sys
job = json.load(sys.stdin)
meta = job["metadata"]
job["metadata"] = {"name": meta["name"], "namespace": meta["namespace"]}
job.pop("status", None)
spec = job["spec"]
spec.pop("selector", None)
spec["template"]["metadata"] = {}
c = spec["template"]["spec"]["containers"][0]
c["volumeMounts"].append({"name": "settings", "mountPath": "/etc/report/report.conf",
                          "subPath": "report.conf"})
print(json.dumps(job))
' > "${TMPDIR:-/tmp}/ex-ts-03-job.json"
kctx -n reports delete job nightly-report --wait=true >/dev/null
kctx apply -f "${TMPDIR:-/tmp}/ex-ts-03-job.json" >/dev/null
rm -f "${TMPDIR:-/tmp}/ex-ts-03-job.json"
kctx -n reports wait --for=condition=Complete job/nightly-report --timeout=120s >/dev/null
