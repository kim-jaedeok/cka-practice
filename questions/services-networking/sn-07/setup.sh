#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"
QID=sn-07
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" commerce

kctx apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: commerce
spec:
  replicas: 2
  selector:
    matchLabels: {app: payments}
  template:
    metadata:
      labels: {app: payments}
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: payments}
      containers:
        - name: nginx
          image: nginx:1.29
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: payments-svc
  namespace: commerce
spec:
  selector: {app: payments}
  ports:
    - port: 80
      targetPort: 8080
EOF

wait_deploy commerce payments

kctx apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: client-worker1
  namespace: commerce
spec:
  nodeName: cka-worker
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 14400"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-worker2
  namespace: commerce
spec:
  nodeName: cka-worker2
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 14400"]
EOF
wait_pod commerce client-worker1 120s
wait_pod commerce client-worker2 120s

payments_json="$(kctx -n commerce get pods -l app=payments -o json)"
python3 -c '
import json, sys
pods = json.loads(sys.argv[1]).get("items", [])
nodes = sorted(pod.get("spec", {}).get("nodeName") for pod in pods)
raise SystemExit(0 if nodes == ["cka-worker", "cka-worker2"] else 1)
' "$payments_json" \
  || die "sn-07 baseline은 payments Pod가 두 worker에 하나씩 있어야 합니다."

worker1_target="$(kctx -n commerce get pods -l app=payments \
  --field-selector spec.nodeName=cka-worker2 -o jsonpath='{.items[0].status.podIP}')"
worker2_target="$(kctx -n commerce get pods -l app=payments \
  --field-selector spec.nodeName=cka-worker -o jsonpath='{.items[0].status.podIP}')"
kctx -n commerce exec client-worker1 -- wget -q -T 3 -O /dev/null \
  "http://$worker1_target" \
  || die "sn-07 cross-node worker1→worker2 Pod 연결 baseline 실패"
kctx -n commerce exec client-worker2 -- wget -q -T 3 -O /dev/null \
  "http://$worker2_target" \
  || die "sn-07 cross-node worker2→worker1 Pod 연결 baseline 실패"

mkdir -p "$CKA_STATE_DIR/question-data/sn-07"
kctx -n commerce get deploy payments -o json | python3 -c '
import hashlib, json, sys
obj = json.load(sys.stdin)
uid = obj["metadata"]["uid"]
spec = json.dumps(obj["spec"], sort_keys=True, separators=(",", ":"))
print(uid + "|" + hashlib.sha256(spec.encode()).hexdigest())
' > "$CKA_STATE_DIR/question-data/sn-07/deployment-fingerprint"
