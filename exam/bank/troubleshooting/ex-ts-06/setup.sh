#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-06
NODE="${CKA_CLUSTER_NAME}-worker2"
MANIFEST=/etc/kubernetes/manifests/edge-cache.yaml
require_cluster

# Remove the static Pod first so that the namespace can be deleted cleanly.
docker exec "$NODE" rm -f "$MANIFEST"
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" edge-system

# The liveness probe asks for a path that the server does not serve. The
# readiness probe uses the right path, so the Pod turns Ready before each kill.
docker exec -i "$NODE" sh -c "cat > $MANIFEST" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: edge-cache
  namespace: edge-system
  labels:
    app: edge-cache
spec:
  terminationGracePeriodSeconds: 5
  containers:
    - name: cache
      image: busybox:1.36
      command:
        - sh
        - -c
        - mkdir -p /www && echo edge-cache-ok > /www/healthz && echo edge-cache > /www/index.html && exec httpd -f -p 8080 -h /www
      ports:
        - name: http
          containerPort: 8080
      readinessProbe:
        httpGet:
          path: /healthz
          port: 8080
        periodSeconds: 5
      livenessProbe:
        httpGet:
          path: /livez
          port: 8080
        initialDelaySeconds: 5
        periodSeconds: 5
        failureThreshold: 2
EOF

for _ in $(seq 1 60); do
  kctx -n edge-system get pod "edge-cache-$NODE" >/dev/null 2>&1 && exit 0
  sleep 2
done
die "ex-ts-06 mirror Pod가 나타나지 않았습니다."
