#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-sn-01
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" legacy-host bridge

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy-conf
  namespace: legacy-host
data:
  default.conf: |
    server {
      listen 80;
      location / { default_type text/plain; return 200 "legacy inventory system v1\n"; }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: legacy-app
  namespace: legacy-host
  labels: {role: legacy}
spec:
  containers:
    - name: nginx
      image: nginx:1.29
      ports:
        - containerPort: 80
      volumeMounts:
        - name: conf
          mountPath: /etc/nginx/conf.d
  volumes:
    - name: conf
      configMap:
        name: legacy-conf
EOF
wait_pod legacy-host legacy-app 180s || die "ex-sn-01 legacy-app이 준비되지 않았습니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n legacy-host get pod legacy-app -o jsonpath='{.metadata.uid}' \
  > "$CKA_STATE_DIR/question-data/$QID/legacy-uid"
