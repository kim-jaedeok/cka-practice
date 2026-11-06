#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-st-03
require_cluster
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" reports-store

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: reports-old
  namespace: reports-store
spec:
  storageClassName: standard
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 256Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-server
  namespace: reports-store
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: report-server
  template:
    metadata:
      labels:
        app: report-server
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: server
          image: busybox:1.36
          command: ["httpd", "-f", "-p", "8080", "-h", "/data"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: reports-old
EOF
wait_deploy reports-store report-server 180s || die "ex-st-03 report-server가 Ready가 아닙니다."

# Write report files with a random part, so that they can only be copied.
token="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
kctx -n reports-store exec deploy/report-server -c server -- sh -c "
  mkdir -p /data/archive
  printf 'quarter,revenue,ref\nq1,1200,$token\n' > /data/q1.csv
  printf 'quarter,revenue,ref\nq2,1350,$token\n' > /data/q2.csv
  printf 'year,total,ref\n2025,4980,$token\n' > /data/archive/2025.csv
  sync" >/dev/null

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n reports-store exec deploy/report-server -c server -- sh -c \
  'cd /data && sha256sum q1.csv q2.csv archive/2025.csv' \
  > "$CKA_STATE_DIR/question-data/$QID/checksums"
