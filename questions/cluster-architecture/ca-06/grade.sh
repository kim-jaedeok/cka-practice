#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ca-06

F="$CKA_WORK_DIR/ca-06/upgrade-commands.txt"

criterion 1 "cka-worker2가 unschedulable (cordoned)" \
  "jp_eq node cka-worker2 - '{.spec.unschedulable}' true"

criterion 1 "cka-worker2에 DaemonSet 외 Pod 없음 (drain 완료)" \
  "node_drained cka-worker2"

criterion 1 "명령 파일: kubeadm 1.36.1-1.1 설치" \
  "file_contains \"$F\" 'kubeadm=1\\.36\\.1-1\\.1'"

criterion 1 "명령 파일: kubeadm upgrade node" \
  "file_contains \"$F\" 'kubeadm[[:space:]]+upgrade[[:space:]]+node'"

criterion 1 "명령 파일: kubelet 1.36.1-1.1 설치 + kubelet 재시작" \
  "file_contains \"$F\" 'kubelet=1\\.36\\.1-1\\.1' && file_contains \"$F\" 'systemctl[[:space:]]+restart[[:space:]]+kubelet'"

criterion 1 "명령 파일: uncordon 포함" \
  "file_contains \"$F\" 'uncordon[[:space:]]+cka-worker2'"

grade_finish
