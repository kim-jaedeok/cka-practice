#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"
CRD=workqueues.queue.example.io

if kctx get crd "$CRD" >/dev/null 2>&1; then
  kctx get workqueues -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | while read -r ns name; do
      [ -n "$name" ] || continue
      kctx -n "$ns" patch workqueue "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
fi
kctx -n tenant-old patch configmap drain-state --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
kctx -n tenant-old delete configmap drain-state --ignore-not-found --wait=false >/dev/null 2>&1 || true
cleanup_question ex-ts-10
kctx delete crd "$CRD" --ignore-not-found --wait=true --timeout=90s >/dev/null
question_state_clear ex-ts-10
