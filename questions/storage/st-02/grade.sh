#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-02

criterion 2 "StorageClass fast-storage 스펙 (provisioner/bindingMode/reclaim)" \
  "jp_eq storageclass fast-storage - '{.provisioner}' rancher.io/local-path && \
   jp_eq storageclass fast-storage - '{.volumeBindingMode}' WaitForFirstConsumer && \
   jp_eq storageclass fast-storage - '{.reclaimPolicy}' Delete"

criterion 1 "PVC data-fast 스펙 (500Mi / RWO / fast-storage)" \
  "jp_eq pvc data-fast project-beta '{.spec.resources.requests.storage}' 500Mi && \
   jp_eq pvc data-fast project-beta '{.spec.storageClassName}' fast-storage && \
   jp_array_has pvc data-fast project-beta '{.spec.accessModes[*]}' ReadWriteOnce && \
   jp_array_count pvc data-fast project-beta '{.spec.accessModes[*]}' 1"

criterion 2 "Pod web-fast가 nginx:1.29로 PVC를 /usr/share/nginx/html에 마운트" \
  "jp_array_has pod web-fast project-beta '{.spec.containers[*].image}' nginx:1.29 && \
   jp_array_count pod web-fast project-beta '{.spec.containers[*].image}' 1 && \
   claim_mounted_at pod web-fast project-beta data-fast /usr/share/nginx/html"

criterion 1 "PVC가 Bound 상태 (동적 프로비저닝 성공)" \
  "jp_eq pvc data-fast project-beta '{.status.phase}' Bound"

criterion 1 "Pod가 Running 상태" \
  "pod_ready project-beta web-fast"

grade_finish
