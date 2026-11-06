#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-07

EXTS07_COMMAND='buf="$(head -c 80000000 /dev/zero | tr '"'"'\0'"'"' x)" && echo "frame buffer ready (${#buf} bytes)" && exec sleep 3600000'

exts07_container_check() { # <mode>
  local json
  json="$(kctx -n media-proc get deploy thumbnailer -o json 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json, re, sys
mode, command = sys.argv[1:3]
spec = json.load(sys.stdin)["spec"]["template"]["spec"]
cs = spec.get("containers", [])
c = cs[0] if len(cs) == 1 else {}
res = c.get("resources", {})

def mib(q):
    m = re.fullmatch(r"([0-9.]+)(Ki|Mi|Gi|K|M|G|k)?", str(q or ""))
    if not m:
        return None
    factor = {None: 1, "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3,
              "k": 1000, "K": 1000, "M": 1000**2, "G": 1000**3}[m.group(2)]
    return float(m.group(1)) * factor / 1024**2

if mode == "process":
    ok = (c.get("name") == "worker" and c.get("image") == "busybox:1.36"
          and c.get("command", []) + c.get("args", []) == ["sh", "-c", command])
elif mode == "request":
    ok = mib(res.get("requests", {}).get("memory")) == 32
elif mode == "limit":
    limit = mib(res.get("limits", {}).get("memory"))
    ok = limit is not None and 0 < limit <= 256
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1" "$EXTS07_COMMAND"
}

# The only Pod of the current ReplicaSet runs without restarts for 15s+.
exts07_stable() {
  deploy_ready media-proc thumbnailer 1 || return 1
  kctx -n media-proc get pods -l app=thumbnailer -o json 2>/dev/null | python3 -c '
import datetime, json, sys
items = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
ok = len(items) == 1
if ok:
    cs = items[0].get("status", {}).get("containerStatuses", [])
    ok = len(cs) == 1 and cs[0].get("restartCount", 1) == 0 and cs[0].get("ready") is True
    started = cs[0].get("state", {}).get("running", {}).get("startedAt") if ok else None
    if started:
        t = datetime.datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        ok = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() >= 15
    else:
        ok = False
raise SystemExit(0 if ok else 1)
'
}

exts07_buffer_loaded() {
  kctx -n media-proc logs deploy/thumbnailer -c worker 2>/dev/null \
    | grep -Fxq 'frame buffer ready (80000000 bytes)'
}

_python3_require || true

criterion 1 "image and command of container worker are unchanged" \
  "exts07_container_check process"

criterion 1 "memory request is still 32Mi" \
  "exts07_container_check request"

criterion 1 "memory limit is set and not larger than 256Mi" \
  "exts07_container_check limit"

criterion 2 "thumbnailer has 1 Ready Pod with 0 restarts for 15s+" \
  "exts07_stable"

criterion 1 "실측: the container loaded its frame buffer" \
  "exts07_buffer_loaded"

grade_finish
