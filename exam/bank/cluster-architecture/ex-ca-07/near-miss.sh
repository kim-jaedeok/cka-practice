#!/usr/bin/env bash
# Near-miss fixture: everything is configured, but the RuntimeClass points at
# the default runc handler instead of the extra handler on the nodes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: sandboxed
handler: runc
overhead:
  podFixed:
    cpu: 100m
    memory: 64Mi
scheduling:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
EOF
kctx -n sandbox-lab patch deploy untrusted-runner --type=merge \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"sandboxed"}}}}' >/dev/null
kctx -n sandbox-lab rollout status deploy/untrusted-runner --timeout=120s >/dev/null
