#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-06

EXTS06_NODE="${CKA_CLUSTER_NAME}-worker2"
EXTS06_POD="edge-cache-$EXTS06_NODE"

exts06_pod_json() {
  kctx -n edge-system get pod "$EXTS06_POD" -o json 2>/dev/null
}

# Python check over the mirror Pod. Mode selects the requirement.
exts06_check() { # <mode>
  local json
  json="$(exts06_pod_json)" || return 1
  printf '%s' "$json" | python3 -c '
import datetime, json, sys
mode, node = sys.argv[1:3]
pod = json.load(sys.stdin)
meta, spec, status = pod["metadata"], pod["spec"], pod.get("status", {})
containers = spec.get("containers", [])
c = containers[0] if len(containers) == 1 else {}
if mode == "static":
    ok = (bool(meta.get("annotations", {}).get("kubernetes.io/config.mirror"))
          and any(r.get("kind") == "Node" and r.get("name") == node
                  for r in meta.get("ownerReferences", []))
          and spec.get("nodeName") == node)
elif mode == "process":
    ok = (c.get("name") == "cache" and c.get("image") == "busybox:1.36"
          and c.get("command", []) + c.get("args", []) == [
              "sh", "-c",
              "mkdir -p /www && echo edge-cache-ok > /www/healthz && "
              "echo edge-cache > /www/index.html && exec httpd -f -p 8080 -h /www"])
elif mode == "liveness":
    ok = bool(c.get("livenessProbe"))
elif mode == "stable":
    cs = [s for s in status.get("containerStatuses", []) if s.get("name") == "cache"]
    ready = any(x.get("type") == "Ready" and x.get("status") == "True"
                for x in status.get("conditions", []))
    ok = False
    if len(cs) == 1 and ready and cs[0].get("restartCount", 1) == 0:
        started = cs[0].get("state", {}).get("running", {}).get("startedAt")
        if started:
            t = datetime.datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
            age = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
            ok = age >= 20
else:
    ok = False
raise SystemExit(0 if ok else 1)
' "$1" "$EXTS06_NODE"
}

# The configured liveness check really succeeds inside the container.
exts06_liveness_target_ok() {
  local json probe
  json="$(exts06_pod_json)" || return 1
  probe="$(printf '%s' "$json" | python3 -c '
import json, sys
c = json.load(sys.stdin)["spec"]["containers"][0]
p = c.get("livenessProbe", {})
ports = {x.get("name"): x.get("containerPort") for x in c.get("ports", [])}
if "httpGet" in p:
    port = p["httpGet"].get("port")
    port = ports.get(port, port)
    print("http", port, p["httpGet"].get("path", "/"))
elif "tcpSocket" in p:
    port = p["tcpSocket"].get("port")
    print("tcp", ports.get(port, port), "-")
elif "exec" in p:
    print("exec", "-", "-")
else:
    raise SystemExit(1)
')" || return 1
  read -r kind port path <<< "$probe"
  local attempt
  for attempt in 1 2 3; do
    case "$kind" in
      http) kctx -n edge-system exec "$EXTS06_POD" -c cache -- \
              wget -q -O /dev/null -T 3 "http://127.0.0.1:${port}${path}" && return 0 ;;
      tcp)  kctx -n edge-system exec "$EXTS06_POD" -c cache -- \
              nc -z -w 3 127.0.0.1 "$port" && return 0 ;;
      exec) exts06_check stable && return 0 ;;
      *)    return 1 ;;
    esac
    sleep 2
  done
  return 1
}

_python3_require || true

criterion 1 "edge-cache is still a static Pod of the kubelet on cka-worker2" \
  "exts06_check static"

criterion 1 "image and command of container cache are unchanged" \
  "exts06_check process"

criterion 1 "container cache still has a liveness probe" \
  "exts06_check liveness"

criterion 1 "실측: the liveness probe target answers inside the container" \
  "exts06_liveness_target_ok"

criterion 2 "Pod is Ready with 0 restarts for at least 20 seconds" \
  "exts06_check stable"

grade_finish
