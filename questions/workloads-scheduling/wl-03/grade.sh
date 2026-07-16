#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init wl-03

criterion 2 "HPA web-cache-hpa가 Deployment web-cache를 대상으로 존재" \
  "jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.scaleTargetRef.kind}' Deployment && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.scaleTargetRef.name}' web-cache"

criterion 2 "min 2 / max 5 replicas 설정" \
  "jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.minReplicas}' 2 && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.maxReplicas}' 5"

criterion 1 "CPU 평균 사용률 60% 목표 메트릭" \
  "jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.metrics[0].resource.name}' cpu && \
   jp_eq hpa.v2.autoscaling web-cache-hpa autoscale '{.spec.metrics[0].resource.target.averageUtilization}' 60"

criterion 1 "HPA에 의해 Deployment가 최소 2개로 스케일됨" \
  "deploy_ready autoscale web-cache 2"

grade_finish
