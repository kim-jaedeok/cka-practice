#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-05

exwl05_spec() { # <mode>
  kctx -n batch-shards get job shard-indexer -o json 2>/dev/null | python3 -c '
import json, sys
mode = sys.argv[1]
job = json.load(sys.stdin)
spec, status = job["spec"], job.get("status", {})
cs = spec.get("template", {}).get("spec", {}).get("containers", [])
if mode == "shape":
    ok = (spec.get("completionMode") == "Indexed" and spec.get("completions") == 4
          and spec.get("parallelism") == 2
          and len(cs) == 1 and cs[0].get("name") == "indexer"
          and cs[0].get("image") == "busybox:1.36")
elif mode == "retry":
    ok = spec.get("backoffLimitPerIndex") == 1
elif mode == "complete":
    ok = status.get("succeeded") == 4 and any(
        c.get("type") == "Complete" and c.get("status") == "True"
        for c in status.get("conditions", []))
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1"
}

# Every index has a succeeded Pod that printed the shard value of its index.
exwl05_outputs() {
  local index pods pod value found
  for index in 0 1 2 3; do
    value="$(kctx -n batch-shards get configmap shard-map -o jsonpath="{.data.shard-$index}" 2>/dev/null)" || return 1
    [ -n "$value" ] || return 1
    pods="$(kctx -n batch-shards get pods -l "job-name=shard-indexer,batch.kubernetes.io/job-completion-index=$index" \
      --field-selector=status.phase=Succeeded -o name 2>/dev/null)" || return 1
    found=1
    for pod in $pods; do
      if kctx -n batch-shards logs "$pod" 2>/dev/null | grep -Fxq "indexed shard $index: $value"; then
        found=0
        break
      fi
    done
    [ "$found" -eq 0 ] || return 1
  done
}

_python3_require || true

criterion 2 "Job shard-indexer is Indexed with 4 completions and parallelism 2" \
  "exwl05_spec shape"

criterion 1 "each index may be retried at most once" \
  "exwl05_spec retry"

criterion 1 "Job shard-indexer is Complete with 4 succeeded Pods" \
  "exwl05_spec complete"

criterion 2 "실측: the Pod of each index printed the shard value of its index" \
  "exwl05_outputs"

grade_finish
