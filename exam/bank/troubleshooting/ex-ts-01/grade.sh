#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ts-01

# Every Running Pod of the Deployment must use the audit-sa identity.
exts01_pods_use_sa() {
  local sas
  sas="$(kctx -n ledger get pods -l app=audit-writer \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' 2>/dev/null)" || return 1
  [ -n "$sas" ] && ! printf '%s\n' "$sas" | grep -vqx audit-sa
}

criterion 1 "ServiceAccount audit-sa exists in ledger" \
  "res_exists serviceaccount audit-sa ledger"

criterion 1 "Deployment keeps serviceAccountName audit-sa and image nginx:1.29" \
  "jp_eq deploy audit-writer ledger '{.spec.template.spec.serviceAccountName}' audit-sa && \
   jp_eq deploy audit-writer ledger '{.spec.template.spec.containers[0].image}' nginx:1.29"

criterion 2 "audit-writer has 2 Ready replicas" \
  "deploy_ready ledger audit-writer 2"

criterion 1 "Running audit-writer Pods use ServiceAccount audit-sa" \
  "exts01_pods_use_sa"

grade_finish
