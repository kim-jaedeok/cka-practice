#!/usr/bin/env bash
# Alternative fixture: stream the files with tar through kubectl exec, from the
# running server into a temporary Pod that mounts only the new claim.
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
  name: receiver
  namespace: reports-store
spec:
  terminationGracePeriodSeconds: 2
  containers:
    - name: rx
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: new
          mountPath: /new
  volumes:
    - name: new
      persistentVolumeClaim:
        claimName: reports-v2
EOF
kctx -n reports-store wait --for=condition=Ready pod/receiver --timeout=180s >/dev/null

kctx -n reports-store exec deploy/report-server -c server -- tar cf - -C /data . \
  | kctx -n reports-store exec -i receiver -c rx -- tar xf - -C /new
kctx -n reports-store exec receiver -c rx -- sync
kctx -n reports-store delete pod receiver --wait=true >/dev/null

kctx -n reports-store patch deploy report-server --type=strategic -p '{"spec":{"template":{"spec":{
  "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"reports-v2"}}]}}}}' >/dev/null
kctx -n reports-store rollout status deploy/report-server --timeout=180s >/dev/null
