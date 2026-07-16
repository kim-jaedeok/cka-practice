#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/grader.sh"

grade_init ts-07

F="$CKA_WORK_DIR/ts-07/errors.log"

criterion 2 "errors.log에 ERROR 라인 존재 (E5, E30 포함)" \
  "file_contains \"$F\" 'ERROR upstream timeout code=E5' && \
   file_contains \"$F\" 'ERROR upstream timeout code=E30'"

criterion 1 "ERROR 라인만 포함 (INFO 라인 없음)" \
  "file_exists \"$F\" && ! grep -q INFO \"$F\""

criterion 1 "ERROR 라인 수가 정확함 (6줄)" \
  "[ \"\$(grep -c ERROR \"$F\" 2>/dev/null)\" = 6 ]"

grade_finish
