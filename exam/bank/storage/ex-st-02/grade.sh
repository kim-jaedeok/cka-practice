#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-st-02

# exst02_template <shape|claim>
exst02_template() {
  local json
  _python3_require || return $?
  json="$(_resource_json deployment renderer render-farm)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
mode = sys.argv[1]
spec = json.load(sys.stdin)["spec"]["template"]["spec"]
vols = [v for v in spec.get("volumes", []) if v.get("name") == "scratch"]
eph = vols[0].get("ephemeral") if len(vols) == 1 else None
if not eph:
    raise SystemExit(1)
tmpl = (eph.get("volumeClaimTemplate") or {}).get("spec") or {}
if mode == "shape":
    mounts = [m for c in spec.get("containers", []) if c.get("name") == "worker"
              for m in c.get("volumeMounts", []) if m.get("name") == "scratch"]
    ok = len(mounts) == 1 and mounts[0].get("mountPath") == "/scratch"
else:
    ok = (tmpl.get("storageClassName") == "standard"
          and tmpl.get("accessModes") == ["ReadWriteOnce"]
          and (tmpl.get("resources") or {}).get("requests", {}).get("storage") == "256Mi")
raise SystemExit(0 if ok else 1)
' "$1"
}

# Every Ready renderer Pod owns a Bound claim <pod>-scratch, and no other claim
# exists in the namespace.
exst02_live_claims() {
  local pods pvcs
  _python3_require || return $?
  pods="$(kctx -n render-farm get pods -l app=renderer -o json 2>/dev/null)" || return 1
  pvcs="$(kctx -n render-farm get pvc -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
pods = [p for p in json.loads(sys.argv[1])["items"] if not p["metadata"].get("deletionTimestamp")
        and any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in p["status"].get("conditions", []))]
claims = [c for c in json.loads(sys.argv[2])["items"] if not c["metadata"].get("deletionTimestamp")]
by_name = {c["metadata"]["name"]: c for c in claims}
ok = len(pods) == 2 and len(claims) == 2
for p in pods:
    c = by_name.get(p["metadata"]["name"] + "-scratch")
    owners = (c or {}).get("metadata", {}).get("ownerReferences", [])
    ok = ok and c is not None and c["status"].get("phase") == "Bound" and any(
        o.get("kind") == "Pod" and o.get("uid") == p["metadata"]["uid"] for o in owners)
raise SystemExit(0 if ok else 1)
' "$pods" "$pvcs"
}

_python3_require || true

criterion 2 "scratch is a generic ephemeral volume mounted at /scratch in worker" \
  "exst02_template shape"

criterion 1 "Claim template: StorageClass standard, ReadWriteOnce, 256Mi" \
  "exst02_template claim"

criterion 1 "renderer rolled out with 2 Ready replicas" \
  "deploy_ready render-farm renderer 2"

criterion 2 "실측: each Ready Pod owns a Bound claim <pod>-scratch and no other claim exists" \
  "exst02_live_claims"

grade_finish
