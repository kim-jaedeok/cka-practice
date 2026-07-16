#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

docker exec -i cka-worker sh -c 'cat > /etc/kubernetes/manifests/static-web.yaml' <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: static-web
spec:
  containers:
    - name: web
      image: nginx:1.29
      ports:
        - containerPort: 80
EOF

# mirror pod가 나타날 때까지 대기
for i in $(seq 1 30); do
  [ "$(kctx get pod static-web-cka-worker -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 3
done
