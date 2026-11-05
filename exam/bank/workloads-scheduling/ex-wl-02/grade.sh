#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-wl-02

exwl02_spec() { # <sources|mode|mount>
  local json
  _python3_require || return $?
  json="$(_resource_json deployment predictor inference)" || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
mode = sys.argv[1]
spec = json.load(sys.stdin)["spec"]["template"]["spec"]
vols = [v for v in spec.get("volumes", []) if v.get("name") == "bundle"]
proj = vols[0].get("projected") if len(vols) == 1 else None
if not proj:
    raise SystemExit(1)
sources = proj.get("sources", [])
cms = [s["configMap"] for s in sources if "configMap" in s]
secs = [s["secret"] for s in sources if "secret" in s]
def items(src):
    return sorted((i.get("key"), i.get("path")) for i in src.get("items", []))
if mode == "sources":
    ok = (len(sources) == 2 and len(cms) == 1 and len(secs) == 1
          and cms[0].get("name") == "model-config"
          and items(cms[0]) == [("model.yaml", "config/model.yaml")]
          and secs[0].get("name") == "model-registry"
          and items(secs[0]) == [("token", "auth/token")])
elif mode == "mode":
    default = proj.get("defaultMode", 0o644)
    modes = [i.get("mode", default) for src in cms + secs for i in src.get("items", [])]
    ok = bool(modes) and all(m == 0o440 for m in modes)
else:
    server = [c for c in spec.get("containers", []) if c.get("name") == "server"]
    mounts = [m for c in server for m in c.get("volumeMounts", []) if m.get("name") == "bundle"]
    ok = (len(mounts) == 1 and mounts[0].get("mountPath") == "/etc/predictor"
          and mounts[0].get("readOnly") is True and not mounts[0].get("subPath"))
raise SystemExit(0 if ok else 1)
' "$1"
}

# A Ready, non-terminating Pod sees exactly the two files with mode 440.
exwl02_live() {
  local pod
  pod="$(kctx -n inference get pods -l app=predictor -o json 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in p.get("status", {}).get("conditions", []))
    if ready and not p["metadata"].get("deletionTimestamp"):
        print(p["metadata"]["name"])
        break
')" || return 1
  [ -n "$pod" ] || return 1
  kctx -n inference exec "$pod" -c server -- sh -c '
    [ "$(ls /etc/predictor)" = "$(printf "auth\nconfig")" ] &&
    [ "$(ls /etc/predictor/config)" = model.yaml ] &&
    [ "$(ls /etc/predictor/auth)" = token ] &&
    grep -qx "name: fraud-detector" /etc/predictor/config/model.yaml &&
    [ "$(cat /etc/predictor/auth/token)" = rgt-5f3a91c0d7e2 ] &&
    [ "$(stat -L -c %a /etc/predictor/config/model.yaml)" = 440 ] &&
    [ "$(stat -L -c %a /etc/predictor/auth/token)" = 440 ]
  ' >/dev/null 2>&1
}

_python3_require || true

criterion 2 "Volume bundle projects only model.yaml and token to the requested paths" \
  "exwl02_spec sources"

criterion 1 "Projected files use mode 0440" \
  "exwl02_spec mode"

criterion 1 "bundle is mounted read-only at /etc/predictor in container server" \
  "exwl02_spec mount"

criterion 1 "predictor has 1 Ready replica" \
  "deploy_ready inference predictor 1"

criterion 2 "실측: the container sees only the two files with mode 440" \
  "exwl02_live"

grade_finish
