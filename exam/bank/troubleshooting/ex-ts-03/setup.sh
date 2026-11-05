#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-03
require_cluster
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" reports

# The script expects /etc/report/report.conf, but the ConfigMap volume is
# mounted at /etc/reports. Both attempts fail, and the Job reaches Failed.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: report-config
  namespace: reports
data:
  report.conf: |
    REPORT_FORMAT=csv
    REPORT_RANGE=24h
---
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
              mountPath: /etc/reports
      volumes:
        - name: settings
          configMap:
            name: report-config
EOF

kctx -n reports wait --for=condition=Failed job/nightly-report --timeout=120s >/dev/null \
  || die "ex-ts-03 baseline Job이 Failed가 되지 않았습니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
python3 - "$CKA_STATE_DIR/question-data/$QID" "$CKA_CONTEXT" <<'PY'
import hashlib, json, subprocess, sys
out, context = sys.argv[1:3]
def get(*args):
    return json.loads(subprocess.check_output(["kubectl", "--context", context, *args, "-o", "json"]))
cm = get("-n", "reports", "get", "configmap", "report-config")
job = get("-n", "reports", "get", "job", "nightly-report")
c = job["spec"]["template"]["spec"]["containers"][0]
with open(f"{out}/configmap-fingerprint", "w") as f:
    f.write(cm["metadata"]["uid"] + "|" + hashlib.sha256(
        json.dumps(cm.get("data", {}), sort_keys=True).encode()).hexdigest() + "\n")
with open(f"{out}/process-fingerprint", "w") as f:
    f.write(hashlib.sha256(json.dumps(
        [c["image"], c.get("command", []) + c.get("args", [])]).encode()).hexdigest() + "\n")
PY
