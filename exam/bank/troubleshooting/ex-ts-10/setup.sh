#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
QID=ex-ts-10
CRD=workqueues.queue.example.io
require_cluster

# Release every finalizer this question owns, also for objects that a forced
# namespace removal may have left behind, before deleting anything.
exts10_release() {
  local ns name
  if kctx get crd "$CRD" >/dev/null 2>&1; then
    kctx get workqueues -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | while read -r ns name; do
        [ -n "$name" ] || continue
        kctx -n "$ns" patch workqueue "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        kctx -n "$ns" delete workqueue "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      done
  fi
  kctx -n tenant-old patch configmap drain-state --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  kctx -n tenant-old delete configmap drain-state --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

exts10_release
cleanup_question "$QID"
question_state_clear "$QID"
kctx delete crd "$CRD" --ignore-not-found --wait=true --timeout=90s >/dev/null
workdir_reset "$QID"

kctx apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: workqueues.queue.example.io
  labels:
    cka-practice/question: ex-ts-10
spec:
  group: queue.example.io
  scope: Namespaced
  names:
    kind: WorkQueue
    plural: workqueues
    singular: workqueue
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
EOF
kctx wait --for=condition=Established "crd/$CRD" --timeout=60s >/dev/null

recreate_ns "$QID" tenant-old tenant-live

# The controller that used to remove these finalizers was uninstalled.
kctx apply -f - >/dev/null <<'EOF'
apiVersion: queue.example.io/v1
kind: WorkQueue
metadata:
  name: orders-q
  namespace: tenant-old
  finalizers:
    - queue.example.io/drain
spec:
  maxDepth: 500
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: drain-state
  namespace: tenant-old
  finalizers:
    - queue.example.io/drain
data:
  pending: "0"
---
apiVersion: queue.example.io/v1
kind: WorkQueue
metadata:
  name: billing-q
  namespace: tenant-live
  finalizers:
    - queue.example.io/drain
spec:
  maxDepth: 200
EOF

mkdir -p "$CKA_STATE_DIR/question-data/$QID"
kctx get crd "$CRD" -o jsonpath='{.metadata.uid}' > "$CKA_STATE_DIR/question-data/$QID/crd-uid"
kctx -n tenant-live get workqueue billing-q -o jsonpath='{.metadata.uid}' \
  > "$CKA_STATE_DIR/question-data/$QID/live-uid"

kctx delete namespace tenant-old --wait=false >/dev/null
for _ in $(seq 1 45); do
  reason="$(kctx get namespace tenant-old \
    -o jsonpath='{.status.conditions[?(@.type=="NamespaceFinalizersRemaining")].status}' 2>/dev/null || true)"
  [ "$reason" = True ] && exit 0
  sleep 2
done
die "ex-ts-10 baseline: tenant-old가 finalizer 대기 상태가 되지 않았습니다."
