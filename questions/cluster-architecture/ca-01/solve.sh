#!/usr/bin/env bash
# 모범 답안 자동 적용 (selftest용) — answer.md와 동일한 내용
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/common.sh"

kctx -n dev-team create role pod-reader \
  --verb=get --verb=list --verb=watch --resource=pods
kctx -n dev-team create rolebinding app-reader-binding \
  --role=pod-reader --serviceaccount=dev-team:app-reader
