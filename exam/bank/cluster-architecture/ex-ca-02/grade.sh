#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/grader.sh"

grade_init ex-ca-02

EXCA02_SA=system:serviceaccount:rollouts:scaler-bot

exca02_can() { # <verb> <resource[/name]> [subresource]
  local out
  if [ -n "${3:-}" ]; then
    out="$(kctx auth can-i "$1" "$2" --subresource="$3" -n rollouts --as "$EXCA02_SA" 2>/dev/null)"
  else
    out="$(kctx auth can-i "$1" "$2" -n rollouts --as "$EXCA02_SA" 2>/dev/null)"
  fi
  [ "$out" = yes ]
}

exca02_cannot() { # <verb> <resource[/name]> [subresource]
  local out
  if [ -n "${3:-}" ]; then
    out="$(kctx auth can-i "$1" "$2" --subresource="$3" -n rollouts --as "$EXCA02_SA" 2>/dev/null)"
  else
    out="$(kctx auth can-i "$1" "$2" -n rollouts --as "$EXCA02_SA" 2>/dev/null)"
  fi
  [ "$out" = no ]
}

exca02_binding() {
  jp_eq role frontend-scaler rollouts '{.metadata.name}' frontend-scaler && \
  jp_eq rolebinding scaler-bot-frontend-scaler rollouts '{.roleRef.kind}/{.roleRef.name}' \
    Role/frontend-scaler && \
  jp_relation_has rolebinding scaler-bot-frontend-scaler rollouts \
    '{range .subjects[*]}{.kind}{"|"}{.name}{"|"}{.namespace}{"\n"}{end}' \
    'ServiceAccount|scaler-bot|rollouts'
}

exca02_read() {
  exca02_can get deployments.apps/frontend && \
  exca02_can list deployments.apps && \
  exca02_can watch deployments.apps
}

exca02_scale_frontend() {
  exca02_can get deployments.apps/frontend scale && \
  exca02_can update deployments.apps/frontend scale && \
  exca02_can patch deployments.apps/frontend scale
}

exca02_denied() {
  exca02_cannot update deployments.apps/backend scale && \
  exca02_cannot patch deployments.apps/backend scale && \
  exca02_cannot update deployments.apps/frontend && \
  exca02_cannot patch deployments.apps/frontend && \
  exca02_cannot delete deployments.apps/frontend
}

criterion 1 "Role frontend-scaler is bound to ServiceAccount scaler-bot" \
  "exca02_binding"

criterion 1 "scaler-bot can get, list and watch Deployments" \
  "exca02_read"

criterion 2 "scaler-bot can get, update and patch deployments/scale of frontend" \
  "exca02_scale_frontend"

criterion 2 "scaler-bot cannot scale backend or modify Deployments directly" \
  "exca02_denied"

criterion 1 "frontend runs 3 Ready replicas and backend stays at 1" \
  "deploy_ready rollouts frontend 3 && deploy_ready rollouts backend 1"

grade_finish
