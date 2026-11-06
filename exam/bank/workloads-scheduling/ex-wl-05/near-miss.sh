#!/usr/bin/env bash
# Near-miss fixture: the Job works, but it runs all 4 Pods at the same time
# instead of at most 2.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: shard-indexer
  namespace: batch-shards
spec:
  completionMode: Indexed
  completions: 4
  parallelism: 4
  backoffLimitPerIndex: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: indexer
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'echo "indexed shard $JOB_COMPLETION_INDEX: $(cat /etc/shards/shard-$JOB_COMPLETION_INDEX)"'
          volumeMounts:
            - name: shards
              mountPath: /etc/shards
      volumes:
        - name: shards
          configMap:
            name: shard-map
EOF
kctx -n batch-shards wait --for=condition=Complete job/shard-indexer --timeout=180s >/dev/null
