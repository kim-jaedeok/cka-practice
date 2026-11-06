#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-08
require_cluster
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" nightly-ops

# The first scheduled run hangs forever while it waits for a lock. The command
# is fixed afterwards, but concurrencyPolicy Forbid keeps skipping every new
# run while the old one is still active.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-vacuum
  namespace: nightly-ops
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          terminationGracePeriodSeconds: 2
          containers:
            - name: vacuum
              image: busybox:1.36
              command:
                - sh
                - -c
                - echo "vacuum started"; echo "waiting for lock on table orders"; sleep 86400
EOF

stuck=""
for _ in $(seq 1 50); do
  stuck="$(kctx -n nightly-ops get cronjob db-vacuum -o jsonpath='{.status.active[0].name}' 2>/dev/null || true)"
  [ -n "$stuck" ] && break
  sleep 2
done
[ -n "$stuck" ] || die "ex-ts-08 baseline: 첫 예약 실행이 시작되지 않았습니다."

kctx -n nightly-ops patch cronjob db-vacuum --type=json -p '[{"op":"replace",
  "path":"/spec/jobTemplate/spec/template/spec/containers/0/command/2",
  "value":"echo \"vacuum started\"; sleep 3; echo \"vacuum complete\""}]' >/dev/null

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
printf '%s\n' "$stuck" > "$CKA_STATE_DIR/question-data/$QID/stuck-job-name"
kctx -n nightly-ops get job "$stuck" -o jsonpath='{.metadata.uid}' \
  > "$CKA_STATE_DIR/question-data/$QID/stuck-job-uid"
