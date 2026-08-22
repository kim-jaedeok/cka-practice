#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${CKA_SSH_SUPERVISOR_DOCKER_SMOKE:-0}" != 1 ]; then
  printf 'SKIP: set CKA_SSH_SUPERVISOR_DOCKER_SMOKE=1 for the isolated Docker smoke\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="$ROOT/exam/ssh/session.sh"
BASE_IMAGE="${CKA_SSH_BASE_IMAGE:-cka-practice/ssh-base:v1}"
TARGET_IMAGE="${CKA_SSH_TARGET_IMAGE:-cka-practice/ssh-target:v1}"
TEST_PARENT="$HOME/.local/state/cka-practice/test-runs"
install -d -m 0700 "$TEST_PARENT"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/cka-ssh-supervisor-docker.XXXXXXXX")"
STATE_ROOT="$TEST_ROOT/state"
RUN_ID="docker-smoke-$$"

case "$TEST_ROOT" in "$TEST_PARENT"/cka-ssh-supervisor-docker.*) ;; *) printf 'unsafe test root\n' >&2; exit 1 ;; esac
install -d -m 0700 "$STATE_ROOT"

remove_test_root() {
  case "$TEST_ROOT" in
    "$TEST_PARENT"/cka-ssh-supervisor-docker.*)
      [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || return 1
      rm -rf -- "$TEST_ROOT"
      ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local original_rc=$? cleanup_rc=0
  trap - EXIT
  if [ -d "$STATE_ROOT/runs/$RUN_ID" ]; then
    CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" seal --run-id "$RUN_ID" --reason operator \
      >/dev/null 2>&1 || true
    if ! CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" cleanup --run-id "$RUN_ID" \
        >/dev/null 2>&1; then
      cleanup_rc=1
      printf 'FAIL: exact-ID cleanup failed; preserved supervisor state at %s\n' "$TEST_ROOT" >&2
    fi
  fi
  if [ "$original_rc" -ne 0 ]; then
    if [ "$cleanup_rc" -eq 0 ]; then
      printf 'FAIL: smoke failed after exact-ID cleanup; preserved supervisor audit at %s\n' "$TEST_ROOT" >&2
    fi
    exit "$original_rc"
  fi
  if [ "$cleanup_rc" -eq 0 ]; then
    remove_test_root
  fi
  exit "$cleanup_rc"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { printf 'Docker is required\n' >&2; exit 1; }
docker info >/dev/null
docker image inspect "$BASE_IMAGE" "$TARGET_IMAGE" >/dev/null \
  || { printf 'Build SSH images first with exam/ssh/build.sh\n' >&2; exit 1; }
[ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ] \
  || { printf 'The opt-in smoke requires WSL systemd\n' >&2; exit 1; }

CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" start \
  --run-id "$RUN_ID" --duration-seconds 30 \
  --base-image "$BASE_IMAGE" --target-image "$TARGET_IMAGE" >/dev/null

manifest="$STATE_ROOT/runs/$RUN_ID/manifest.json"
target_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["objects"]["target"]["id"])' "$manifest")"
docker container rename "$target_id" "cka-renamed-smoke-$$"

CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" seal --run-id "$RUN_ID" --reason manual >/dev/null
CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" authorize-grade --run-id "$RUN_ID" >/dev/null
[ "$(docker container inspect --format '{{.State.Running}}' "$target_id")" = false ]
CKA_SSH_SUPERVISOR_STATE_ROOT="$STATE_ROOT" bash "$SESSION" cleanup --run-id "$RUN_ID" >/dev/null

trap - EXIT
remove_test_root
printf 'PASS: isolated supervisor Docker smoke (no kind network used)\n'
