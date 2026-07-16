#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init st-01

criterion 1 "PV pv-alpha 존재" \
  "res_exists pv pv-alpha"

criterion 2 "PV 스펙: 2Gi / RWO / hostPath /data/pv-alpha / class manual / Retain" \
  "jp_eq pv pv-alpha - '{.spec.capacity.storage}' 2Gi && \
   jp_eq pv pv-alpha - '{.spec.accessModes[0]}' ReadWriteOnce && \
   jp_eq pv pv-alpha - '{.spec.hostPath.path}' /data/pv-alpha && \
   jp_eq pv pv-alpha - '{.spec.storageClassName}' manual && \
   jp_eq pv pv-alpha - '{.spec.persistentVolumeReclaimPolicy}' Retain"

criterion 1 "PVC pvc-alpha가 project-alpha에 존재" \
  "res_exists pvc pvc-alpha project-alpha"

criterion 1 "PVC 스펙: 1Gi 요청 / RWO / class manual" \
  "jp_eq pvc pvc-alpha project-alpha '{.spec.resources.requests.storage}' 1Gi && \
   jp_eq pvc pvc-alpha project-alpha '{.spec.accessModes[0]}' ReadWriteOnce && \
   jp_eq pvc pvc-alpha project-alpha '{.spec.storageClassName}' manual"

criterion 1 "PVC가 pv-alpha에 Bound" \
  "jp_eq pvc pvc-alpha project-alpha '{.status.phase}' Bound && \
   jp_eq pvc pvc-alpha project-alpha '{.spec.volumeName}' pv-alpha"

grade_finish
