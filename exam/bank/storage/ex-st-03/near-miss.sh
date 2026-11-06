#!/usr/bin/env bash
# Near-miss fixture: the new claim is created and mounted, but the data was
# never copied, so the server now serves an empty volume.
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
EOF
kctx -n reports-store patch deploy report-server --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"reports-v2"}]' >/dev/null
kctx -n reports-store rollout status deploy/report-server --timeout=180s >/dev/null
