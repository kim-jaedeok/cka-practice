#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-06
require_cluster
cleanup_question "$QID"
question_state_clear "$QID"
workdir_reset "$QID"
recreate_ns "$QID" quorum

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: kv
  namespace: quorum
spec:
  clusterIP: None
  selector:
    app: kv
  ports:
    - name: http
      port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kv
  namespace: quorum
spec:
  serviceName: kv
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: kv
  template:
    metadata:
      labels:
        app: kv
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: kv
          image: nginx:1.28
          ports:
            - name: http
              containerPort: 80
EOF
kctx -n quorum rollout status sts/kv --timeout=180s >/dev/null \
  || die "ex-wl-06 StatefulSet kv가 Ready가 아닙니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
for i in 0 1 2; do
  kctx -n quorum get pod "kv-$i" -o jsonpath='{.metadata.uid}' \
    > "$CKA_STATE_DIR/question-data/$QID/kv-$i-uid"
done
