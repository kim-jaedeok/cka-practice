#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-04

wl04_probe_config() { # <readiness|liveness>
  local probe="$1"
  kctx -n dept-y get deploy health-api -o json 2>/dev/null | python3 -c '
import json, sys
probe_name = sys.argv[1]
containers = json.load(sys.stdin)["spec"]["template"]["spec"].get("containers", [])
matches = [container for container in containers if container.get("name") == "api"]
if len(matches) != 1 or matches[0].get("image") != "nginx:1.29":
    raise SystemExit(1)
probe = matches[0].get(probe_name + "Probe", {})
if probe_name == "readiness":
    http = probe.get("httpGet", {})
    ok = (
        http.get("path") == "/"
        and http.get("port") == 80
        and probe.get("initialDelaySeconds") == 5
        and probe.get("periodSeconds") == 10
    )
else:
    tcp = probe.get("tcpSocket", {})
    ok = (
        tcp.get("port") == 80
        and probe.get("initialDelaySeconds") == 15
        and probe.get("periodSeconds") == 20
    )
raise SystemExit(0 if ok else 1)
' "$probe"
}

_python3_require || true

criterion 3 "readinessProbe: httpGet / :80, initialDelay 5, period 10" \
  "wl04_probe_config readiness"

criterion 2 "livenessProbe: tcpSocket :80, initialDelay 15, period 20" \
  "wl04_probe_config liveness"

criterion 1 "Deployment 롤아웃 성공 (2/2 Ready)" \
  "deploy_ready dept-y health-api 2"

grade_finish
