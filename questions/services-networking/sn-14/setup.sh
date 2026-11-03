#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-14
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" edge

kctx apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: echo-conf
  namespace: edge
data:
  default.conf: |
    server {
      listen 80;
      location / { return 200 "$remote_addr\n"; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: edge
spec:
  replicas: 1
  selector:
    matchLabels: {app: echo}
  template:
    metadata:
      labels: {app: echo}
    spec:
      nodeSelector: {kubernetes.io/hostname: cka-worker}
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
            name: echo-conf
---
apiVersion: v1
kind: Service
metadata:
  name: echo-svc
  namespace: edge
spec:
  type: NodePort
  selector: {app: echo}
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30880
EOF
wait_deploy edge echo 180s || die "sn-14 baseline echo Deployment가 준비되지 않았습니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
{
  kctx -n edge get deploy echo -o json
  kctx -n edge get configmap echo-conf -o json
} | python3 -c '
import hashlib, json, sys
decoder = json.JSONDecoder(); text = sys.stdin.read(); pos = 0; parts = []
while pos < len(text):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    value, pos = decoder.raw_decode(text, pos)
    parts.append(value["metadata"]["uid"] + json.dumps(
        value.get("spec", value.get("data")), sort_keys=True, separators=(",", ":")))
print(hashlib.sha256("|".join(parts).encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/$QID/workload-fingerprint"
