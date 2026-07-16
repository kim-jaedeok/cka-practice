#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-06

criterion 1 "Pod dns-checker가 Running (busybox)" \
  "pod_running dns-test dns-checker && \
   jp_contains pod dns-checker dns-test '{.spec.containers[0].image}' busybox"

criterion 2 "svc.txt: web-dns 서비스 조회 결과 저장 (이름 + 서비스 IP 일치)" \
  "file_contains \"\$CKA_WORK_DIR/sn-06/svc.txt\" 'web-dns.dns-test.svc.cluster.local' && \
   file_contains \"\$CKA_WORK_DIR/sn-06/svc.txt\" \"\$(_jp_get svc web-dns dns-test '{.spec.clusterIP}')\""

criterion 2 "kubernetes.txt: kubernetes 서비스 조회 결과 저장 (이름 + 서비스 IP 일치)" \
  "file_contains \"\$CKA_WORK_DIR/sn-06/kubernetes.txt\" 'kubernetes.default.svc.cluster.local' && \
   file_contains \"\$CKA_WORK_DIR/sn-06/kubernetes.txt\" \"\$(_jp_get svc kubernetes default '{.spec.clusterIP}')\""

grade_finish
