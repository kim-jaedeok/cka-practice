#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-05
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" mapping

# geo-resolver uses dnsPolicy None with a documentation-range nameserver
# (192.0.2.53, RFC 5737), so its exec readiness probe never resolves the
# Service name. Only this workload is affected.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tiles
  namespace: mapping
spec:
  replicas: 1
  selector:
    matchLabels: {app: tiles}
  template:
    metadata:
      labels: {app: tiles}
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: tiles-api
  namespace: mapping
spec:
  selector: {app: tiles}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geo-resolver
  namespace: mapping
spec:
  replicas: 2
  selector:
    matchLabels: {app: geo-resolver}
  template:
    metadata:
      labels: {app: geo-resolver}
    spec:
      dnsPolicy: None
      dnsConfig:
        nameservers:
          - 192.0.2.53
        searches:
          - mapping.svc.cluster.local
        options:
          - name: ndots
            value: "2"
          - name: timeout
            value: "1"
      containers:
        - name: resolver
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          readinessProbe:
            exec:
              command: ["nslookup", "tiles-api.mapping.svc.cluster.local"]
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 1
EOF

wait_deploy mapping tiles 180s || die "ex-ts-05 tiles가 준비되지 않았습니다."
kctx -n mapping wait --for=jsonpath='{.status.phase}'=Running pods -l app=geo-resolver \
  --timeout=120s >/dev/null || die "ex-ts-05 geo-resolver Pod가 Running이 아닙니다."
sleep 8
[ "$(kctx -n mapping get deploy geo-resolver -o jsonpath='{.status.readyReplicas}')" = "" ] \
  || die "ex-ts-05 baseline은 Ready replica가 없어야 합니다."

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx -n mapping get deploy geo-resolver -o json | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
c = obj["spec"]["template"]["spec"]["containers"][0]
print(hashlib.sha256(json.dumps(c.get("readinessProbe"), sort_keys=True).encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/$QID/probe-fingerprint"
python3 - "$CKA_CONTEXT" > "$CKA_STATE_DIR/question-data/$QID/backend-fingerprint" <<'PY'
import hashlib, json, subprocess, sys
ctx = sys.argv[1]
def get(kind, name):
    return json.loads(subprocess.check_output(
        ["kubectl", "--context", ctx, "-n", "mapping", "get", kind, name, "-o", "json"]))
svc = get("service", "tiles-api")
dep = get("deployment", "tiles")
print(svc["metadata"]["uid"] + "|" + dep["metadata"]["uid"] + "|" + hashlib.sha256(json.dumps(
    [svc["spec"]["selector"], svc["spec"]["ports"], dep["spec"]["template"]],
    sort_keys=True).encode()).hexdigest())
PY
