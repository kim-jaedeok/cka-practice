#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: reports-v2
  namespace: reports-store
spec:
  storageClassName: standard
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 512Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: copier
  namespace: reports-store
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: busybox:1.36
      command: ["sh", "-c", "cp -a /old/. /new/ && ls -R /new"]
      volumeMounts:
        - name: old
          mountPath: /old
          readOnly: true
        - name: new
          mountPath: /new
  volumes:
    - name: old
      persistentVolumeClaim:
        claimName: reports-old
    - name: new
      persistentVolumeClaim:
        claimName: reports-v2
EOF
kctx -n reports-store wait --for=jsonpath='{.status.phase}'=Succeeded pod/copier --timeout=180s >/dev/null
kctx -n reports-store delete pod copier --wait=true >/dev/null

kctx -n reports-store patch deploy report-server --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"reports-v2"}]' >/dev/null
kctx -n reports-store rollout status deploy/report-server --timeout=180s >/dev/null
