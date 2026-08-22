#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init sn-06

criterion 1 "Pod dns-checker가 Running (busybox:1.36, sleep infinity)" \
  "pod_running dns-test dns-checker && \
   container_process_is pod dns-checker dns-test - busybox:1.36 sleep infinity"

criterion 2 "svc.txt가 dns-checker의 web-dns nslookup 전체 stdout과 일치" \
  "file_exact_nonblank_command_output \"\$CKA_WORK_DIR/sn-06/svc.txt\" \
     kctx -n dns-test exec dns-checker -- \
     nslookup web-dns.dns-test.svc.cluster.local"

criterion 2 "kubernetes.txt가 dns-checker의 kubernetes nslookup 전체 stdout과 일치" \
  "file_exact_nonblank_command_output \"\$CKA_WORK_DIR/sn-06/kubernetes.txt\" \
     kctx -n dns-test exec dns-checker -- \
     nslookup kubernetes.default.svc.cluster.local"

grade_finish
