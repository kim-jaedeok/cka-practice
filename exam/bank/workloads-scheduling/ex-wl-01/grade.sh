#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-01

exwl01_strategy() {
  jp_eq deploy order-api orders '{.spec.strategy.type}' RollingUpdate && \
  jp_eq deploy order-api orders '{.spec.strategy.rollingUpdate.maxSurge}' 1 && \
  { jp_eq deploy order-api orders '{.spec.strategy.rollingUpdate.maxUnavailable}' 0 || \
    jp_eq deploy order-api orders '{.spec.strategy.rollingUpdate.maxUnavailable}' 0%; }
}

# The ReplicaSet with the highest revision runs nginx:1.29 and carries the
# change cause that rollout history prints.
exwl01_change_cause() {
  local json uid
  _python3_require || return $?
  uid="$(_jp_get deploy order-api orders '{.metadata.uid}')" || return 1
  json="$(kctx -n orders get rs -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
uid = sys.argv[1]
owned = [rs for rs in json.load(sys.stdin)["items"]
         if any(o.get("uid") == uid for o in rs["metadata"].get("ownerReferences", []))]
def rev(rs):
    try:
        return int(rs["metadata"].get("annotations", {}).get("deployment.kubernetes.io/revision", "0"))
    except ValueError:
        return 0
if not owned:
    raise SystemExit(1)
top = max(owned, key=rev)
image = top["spec"]["template"]["spec"]["containers"][0]["image"]
cause = top["metadata"].get("annotations", {}).get("kubernetes.io/change-cause")
raise SystemExit(0 if image == "nginx:1.29" and cause == "upgrade nginx to 1.29" else 1)
' "$uid"
}

_python3_require || true

criterion 1 "RollingUpdate with maxSurge 1 and maxUnavailable 0" \
  "exwl01_strategy"

criterion 1 "revisionHistoryLimit is 5" \
  "jp_eq deploy order-api orders '{.spec.revisionHistoryLimit}' 5"

criterion 1 "Container image is nginx:1.29" \
  "jp_eq deploy order-api orders '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 2 "Newest revision runs nginx:1.29 and records the change cause" \
  "exwl01_change_cause"

criterion 2 "order-api rolled out with 4 Ready replicas" \
  "deploy_ready orders order-api 4"

grade_finish
