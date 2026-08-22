#!/usr/bin/env bash
# Docker-only smoke test for input copy, real SSH, seal, and answer recovery.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
case "$TMP" in /tmp/*|/var/tmp/*) ;; *) printf 'unsafe temp path: %s\n' "$TMP" >&2; exit 1 ;; esac
run_id="smoke${BASHPID:-$$}${RANDOM:-0}"
run_id="${run_id:0:32}"

cleanup() {
  bash "$SCRIPT_DIR/cleanup.sh" --run-id "$run_id" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/work/ca-08/base" "$TMP/work/ts-07" "$TMP/work/ts-08"
printf 'trusted-input\n' > "$TMP/work/ca-08/base/input.txt"
printf 'ca-08\nts-07\nts-08\n' > "$TMP/questions"

bash "$SCRIPT_DIR/start.sh" \
  --run-id "$run_id" \
  --kubeconfig "ca-08=$SCRIPT_DIR/testdata/smoke-kubeconfig.yaml" \
  --kubeconfig "ts-07=$SCRIPT_DIR/testdata/smoke-kubeconfig.yaml" \
  --kubeconfig "ts-08=$SCRIPT_DIR/testdata/smoke-kubeconfig.yaml" \
  --active-question ca-08 \
  --workdir-root "$TMP/work" \
  --questions-file "$TMP/questions" >/dev/null

base_id="$(docker container inspect --format '{{.Id}}' "cka-ssh-${run_id}-base")"
docker exec --user candidate "$base_id" ssh -o BatchMode=yes cka-target '
  set -eu
  grep -Fx trusted-input "$HOME/cka/ca-08/base/input.txt" >/dev/null
  printf "ERROR smoke-answer\n" > "$HOME/cka/ts-07/errors.log"
'

bash "$SCRIPT_DIR/seal.sh" --run-id "$run_id" >/dev/null
[ "$(docker container inspect --format '{{.State.Running}}' "cka-ssh-${run_id}-target")" = false ]
[ "$(docker container inspect --format '{{.State.Running}}' "cka-ssh-${run_id}-base")" = false ]

bash "$SCRIPT_DIR/collect-work.sh" \
  --run-id "$run_id" \
  --destination-root "$TMP/work" \
  --questions-file "$TMP/questions" \
  --stage-root "$TMP/collected" >/dev/null

grep -Fx 'ERROR smoke-answer' "$TMP/work/ts-07/errors.log" >/dev/null
[ ! -e "$TMP/work/ts-08/top-pod.txt" ]
bash "$SCRIPT_DIR/cleanup.sh" --run-id "$run_id" >/dev/null
! docker container inspect "cka-ssh-${run_id}-base" >/dev/null 2>&1
! docker container inspect "cka-ssh-${run_id}-target" >/dev/null 2>&1
! docker network inspect "cka-ssh-${run_id}-net" >/dev/null 2>&1
printf 'SSH live smoke passed: input copy -> real SSH -> manual seal -> bounded answer recovery -> cleanup\n'
