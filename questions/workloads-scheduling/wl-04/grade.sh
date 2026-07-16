#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-04

criterion 3 "readinessProbe: httpGet / :80, initialDelay 5, period 10" \
  "jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' / && \
   jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].readinessProbe.httpGet.port}' 80 && \
   jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds}' 5 && \
   jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].readinessProbe.periodSeconds}' 10"

criterion 2 "livenessProbe: tcpSocket :80, initialDelay 15, period 20" \
  "jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].livenessProbe.tcpSocket.port}' 80 && \
   jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}' 15 && \
   jp_eq deploy health-api dept-y '{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 20"

criterion 1 "Deployment 롤아웃 성공 (2/2 Ready)" \
  "deploy_ready dept-y health-api 2"

grade_finish
