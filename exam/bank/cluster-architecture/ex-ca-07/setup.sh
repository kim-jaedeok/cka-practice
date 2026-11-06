#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ca-07
require_cluster

# kind configures a second containerd runtime handler on every node. The
# candidate has to find its name in the node's containerd configuration.
for node in "${CKA_CLUSTER_NAME}-worker" "${CKA_CLUSTER_NAME}-worker2"; do
  docker exec "$node" grep -q 'runtimes.test-handler\]' /etc/containerd/config.toml \
    || die "ex-ca-07: $node 에 test-handler runtime이 없습니다."
done

kctx delete runtimeclass sandboxed --ignore-not-found --wait=true >/dev/null
cleanup_question "$QID"
workdir_reset "$QID"
recreate_ns "$QID" sandbox-lab

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-runner
  namespace: sandbox-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: untrusted-runner
  template:
    metadata:
      labels:
        app: untrusted-runner
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: runner
          image: busybox:1.36
          command: ["sleep", "3600000"]
          resources:
            requests:
              cpu: 20m
              memory: 16Mi
EOF
wait_deploy sandbox-lab untrusted-runner || die "ex-ca-07 baseline Deployment가 Ready가 아닙니다."
