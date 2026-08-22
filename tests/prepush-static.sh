#!/usr/bin/env bash
# Fail-fast, cluster-free release checks. Run from a native Linux/WSL shell.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  printf 'prepush-static: Python interpreter unavailable\n' >&2
  exit 1
fi

run() {
  local label="$1"
  shift
  printf '\n==> %s\n' "$label"
  "$@"
}

run "Python unit tests" \
  "$PYTHON_BIN" -m unittest discover -s tests -p 'test_*.py'
run "grader contract" bash tests/contract-test.sh
run "mock exam runner contract" bash tests/exam-runner-test.sh
run "question runtime contract" bash tests/question-runtime-contract-test.sh
run "shared cluster recovery contract" bash tests/cluster-recovery-contract-test.sh
run "ts-13 generation recovery contract" bash tests/ts13-generation-contract-test.sh
run "kubeadm cell contract" bash tests/kubeadm-cell-contract-test.sh
run "operator and Gateway contract" bash tests/operator-gateway-contract-test.sh
run "LoadBalancer provider contract" bash tests/provider-contract-test.sh
run "SSH exam contract" bash exam/ssh/contract-test.sh
run "SSH supervisor fault suite" env PYTHON="$PYTHON_BIN" bash tests/ssh-supervisor-faults.sh
run "SSH runner fault suite" env PYTHON="$PYTHON_BIN" bash tests/ssh-runner-faults.sh

printf '\nPASS: all cluster-free pre-push checks\n'
