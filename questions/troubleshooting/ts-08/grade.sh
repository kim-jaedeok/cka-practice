#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-08

F="$CKA_WORK_DIR/ts-08/top-pod.txt"

criterion 2 "top-pod.txt 파일 존재 (Pod 이름 1줄)" \
  "file_exists \"$F\""

criterion 3 "실제 CPU 최다 사용 Pod와 일치 (채점 시점 kubectl top 기준)" \
  "[ \"\$(cat \"$F\" 2>/dev/null | tr -d '[:space:]')\" = \"\$(kctx -n monitor top pods --no-headers 2>/dev/null | sort -k2 -rh | head -1 | awk '{print \$1}')\" ]"

grade_finish
