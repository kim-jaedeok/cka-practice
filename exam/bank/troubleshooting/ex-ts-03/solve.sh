#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

mkdir -p "$CKA_WORK_DIR/ex-ts-03"
kctx -n reports logs job/nightly-report > "$CKA_WORK_DIR/ex-ts-03/job-error.log"

# A Job's Pod template is immutable: delete the Job and create it again with
# the ConfigMap mounted where the script reads it.
kctx -n reports delete job nightly-report --wait=true >/dev/null
kctx apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: nightly-report
  namespace: reports
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: report
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              if [ ! -f /etc/report/report.conf ]; then
                echo "FATAL: settings file /etc/report/report.conf is missing (code RPT-417)"
                exit 3
              fi
              . /etc/report/report.conf
              echo "report generated format=${REPORT_FORMAT} range=${REPORT_RANGE}"
          volumeMounts:
            - name: settings
              mountPath: /etc/report
      volumes:
        - name: settings
          configMap:
            name: report-config
EOF
kctx -n reports wait --for=condition=Complete job/nightly-report --timeout=120s >/dev/null
