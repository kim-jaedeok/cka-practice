#!/usr/bin/env bash
# Near-miss fixture: a normal ClusterIP Service resolves to one virtual IP
# instead of the worker Pod IPs, so it misses the headless requirement.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: workers
  namespace: training
spec:
  selector: {app: worker}
  ports:
    - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: worker
  namespace: training
spec:
  serviceName: workers
  replicas: 2
  selector:
    matchLabels: {app: worker}
  template:
    metadata:
      labels: {app: worker}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF
kctx -n training rollout status statefulset/worker --timeout=180s >/dev/null
mkdir -p "$CKA_WORK_DIR/sn-13"
printf '%s\n' worker-1.workers.training.svc.cluster.local > "$CKA_WORK_DIR/sn-13/worker-1-fqdn.txt"
sleep 3
