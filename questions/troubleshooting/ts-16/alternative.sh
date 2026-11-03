#!/usr/bin/env bash
# Alternative fixture: keep the probe path /healthz and make nginx serve it from
# a ConfigMap. The probe stays an HTTP probe on port 80, so this earns full credit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n inventory create configmap stock-health --from-literal=healthz=ok \
  --dry-run=client -o yaml | kctx apply -f - >/dev/null
kctx -n inventory patch deploy stock-api --type=strategic -p '
spec:
  template:
    spec:
      volumes:
        - name: health
          configMap:
            name: stock-health
      containers:
        - name: nginx
          volumeMounts:
            - name: health
              mountPath: /usr/share/nginx/html/healthz
              subPath: healthz
' >/dev/null
wait_deploy inventory stock-api 180s
sleep 3
