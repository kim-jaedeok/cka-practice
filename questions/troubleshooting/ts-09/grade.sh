#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-09

criterion 3 "report-pvc가 report-pv에 Bound" \
  "jp_eq pvc report-pvc data-layer '{.status.phase}' Bound && \
   jp_eq pvc report-pvc data-layer '{.spec.volumeName}' report-pv"

criterion 2 "report-app Pod가 Running" \
  "pod_ready data-layer report-app"

criterion 1 "PV는 수정되지 않음 (storageClassName: reports 유지)" \
  "jp_eq pv report-pv - '{.spec.storageClassName}' reports"

grade_finish
