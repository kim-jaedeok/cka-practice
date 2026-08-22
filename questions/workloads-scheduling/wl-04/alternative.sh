#!/usr/bin/env bash
# Semantically valid alternative: keep an unrelated sidecar before the named
# api container. The grader must locate the container by name, not array index.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dept-y patch deploy health-api --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers","value":[
    {"name":"sidecar","image":"busybox:1.36","command":["sleep","14400"]},
    {"name":"api","image":"nginx:1.29",
     "readinessProbe":{"httpGet":{"path":"/","port":80},"initialDelaySeconds":5,"periodSeconds":10},
     "livenessProbe":{"tcpSocket":{"port":80},"initialDelaySeconds":15,"periodSeconds":20}}
  ]}
]' >/dev/null
wait_deploy dept-y health-api 180s
