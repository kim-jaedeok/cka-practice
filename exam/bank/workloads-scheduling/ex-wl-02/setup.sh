#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-wl-02
require_cluster
cleanup_question "$QID"
recreate_ns "$QID" inference

kctx apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: model-config
  namespace: inference
data:
  model.yaml: |
    name: fraud-detector
    version: 7
    batchSize: 32
  labels.txt: |
    legit
    fraud
---
apiVersion: v1
kind: Secret
metadata:
  name: model-registry
  namespace: inference
type: Opaque
stringData:
  token: rgt-5f3a91c0d7e2
  username: predictor-bot
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: predictor
  namespace: inference
spec:
  replicas: 1
  selector:
    matchLabels: {app: predictor}
  template:
    metadata:
      labels: {app: predictor}
    spec:
      containers:
        - name: server
          image: nginx:1.29
          ports:
            - containerPort: 80
EOF
wait_deploy inference predictor 180s || die "ex-wl-02 predictor가 준비되지 않았습니다."
