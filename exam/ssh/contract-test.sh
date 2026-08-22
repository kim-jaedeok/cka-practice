#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
case "$TMP" in /tmp/*|/var/tmp/*) ;; *) printf 'unsafe temp path: %s\n' "$TMP" >&2; exit 1 ;; esac
trap 'rm -rf -- "$TMP"' EXIT
passes=0

pass() {
  passes=$((passes + 1))
  printf 'ok %d - %s\n' "$passes" "$1"
}

assert_contains() {
  local file="$1" text="$2" description="$3"
  grep -F -- "$text" "$file" >/dev/null || {
    printf 'not ok - %s\n' "$description" >&2
    exit 1
  }
  pass "$description"
}

assert_absent() {
  local file="$1" text="$2" description="$3"
  if grep -F -- "$text" "$file" >/dev/null; then
    printf 'not ok - %s\n' "$description" >&2
    exit 1
  fi
  pass "$description"
}

for script in "$SCRIPT_DIR"/*.sh \
  "$REPO_ROOT/images/target/files/entrypoint.sh" \
  "$REPO_ROOT/images/target/files/cka-use-context"; do
  bash -n "$script"
done
pass 'all SSH environment scripts pass bash syntax checks'

assert_contains "$REPO_ROOT/images/base/Dockerfile" 'org.cka-practice.ssh-image-role="base"' \
  'base image has a verifiable role label'
assert_contains "$REPO_ROOT/images/base/Dockerfile" 'if command -v "$tool"' \
  'base image fails its build if a forbidden work tool is present'
assert_absent "$SCRIPT_DIR/start.sh" '/var/run/docker.sock' \
  'runner never exposes the Docker socket'
assert_absent "$SCRIPT_DIR/start.sh" "$REPO_ROOT" \
  'runner never embeds or mounts the repository path'
assert_contains "$SCRIPT_DIR/start.sh" 'docker network create --driver bridge --internal' \
  'each run creates an externally isolated SSH network'
assert_contains "$REPO_ROOT/images/target/files/sshd_config" 'AllowTcpForwarding no' \
  'SSH forwarding is disabled on the target'
assert_contains "$REPO_ROOT/images/target/files/sshd_config" 'DisableForwarding yes' \
  'all OpenSSH forwarding features are disabled on the target'
assert_contains "$REPO_ROOT/images/target/files/sshd_config" 'AuthenticationMethods publickey' \
  'target accepts public-key authentication only'
assert_contains "$REPO_ROOT/images/target/Dockerfile" 'rm -f /usr/bin/ssh /usr/bin/slogin /usr/bin/scp /usr/bin/sftp' \
  'target removes nested SSH clients'
assert_contains "$REPO_ROOT/images/target/Dockerfile" 'ln -s kubectl /usr/local/bin/k' \
  'target provides the k shortcut'
assert_contains "$REPO_ROOT/images/target/files/cka-bashrc" 'kubectl completion bash' \
  'target enables kubectl Bash completion'
assert_contains "$SCRIPT_DIR/start.sh" 'cka-use-context "$active_question"' \
  'runner activates a question-specific kubeconfig'
assert_contains "$SCRIPT_DIR/start.sh" 'sha256sum --check --strict' \
  'runner verifies pinned tool bytes inside the live target'
assert_contains "$SCRIPT_DIR/seal.sh" 'docker container stop --time 0 "$target_id"' \
  'seal stops the target and all candidate background processes'
assert_contains "$SCRIPT_DIR/cleanup.sh" 'docker container rm --force "$base_id"' \
  'cleanup deletes the immutable ID captured with its ownership label'

assert_absent "$REPO_ROOT/exam/mock-exam.sh" '--ssh' \
  'host exam runner exposes no SSH activation flag'
assert_absent "$REPO_ROOT/exam/mock-exam.sh" 'seal_and_collect_ssh_answers' \
  'experimental SSH lifecycle is not connected to host grading'
assert_contains "$SCRIPT_DIR/deadline-watcher.sh" \
  'run_record_matches "$exam_dir/ssh-environment-disposed"' \
  'watcher validates the disposed proof instead of trusting marker existence'
assert_contains "$SCRIPT_DIR/collect-work.sh" \
  "[ \"\$(docker container inspect --format '{{.State.Running}}' \"\$target_id\")\" = false ]" \
  'answer collection refuses a running target'

bash "$SCRIPT_DIR/gated-form.sh" --catalog-out "$TMP/catalog.tsv" >/dev/null
CKA_FORM_CATALOG="$TMP/catalog.tsv" bash "$REPO_ROOT/exam/planner.sh" \
  --seed ssh-contract \
  --questions-out "$TMP/form" \
  --setup-order-out "$TMP/setup" >/dev/null
bash "$SCRIPT_DIR/gated-form.sh" --verify-form "$TMP/form" >/dev/null
for forbidden in ca-03 ca-04 ca-06 ca-07 ca-10 ts-05 ts-11 ts-12 ts-13 ts-14 ts-15 sn-04; do
  ! grep -qx "$forbidden" "$TMP/form" || {
    printf 'not ok - gated form contains %s\n' "$forbidden" >&2
    exit 1
  }
done
pass 'gated planner produces 17 supported questions and excludes node-shell/tool gaps'

mkdir -p "$TMP/source" "$TMP/output"
printf 'bounded answer\n' > "$TMP/source/answer.txt"
tar -cf "$TMP/answer.tar" -C "$TMP/source" answer.txt
python3 "$SCRIPT_DIR/extract-answer.py" \
  --name answer.txt --output "$TMP/output/answer.txt" < "$TMP/answer.tar"
cmp -s "$TMP/source/answer.txt" "$TMP/output/answer.txt" || {
  printf 'not ok - bounded answer extraction changed content\n' >&2
  exit 1
}
pass 'allowlisted regular answer is extracted from a bounded tar stream'

set +e
python3 "$SCRIPT_DIR/extract-answer.py" \
  --name missing.txt --output "$TMP/output/missing.txt" </dev/null >/dev/null 2>&1
empty_rc=$?
set -e
[ "$empty_rc" -eq 20 ] || {
  printf 'not ok - empty answer stream returned %s\n' "$empty_rc" >&2
  exit 1
}
pass 'missing answer has a distinct non-infrastructure result'

ln -s answer.txt "$TMP/source/link.txt"
tar -cf "$TMP/link.tar" -C "$TMP/source" link.txt
set +e
python3 "$SCRIPT_DIR/extract-answer.py" \
  --name link.txt --output "$TMP/output/link.txt" < "$TMP/link.tar" >/dev/null 2>&1
link_rc=$?
set -e
[ "$link_rc" -eq 21 ] && [ ! -e "$TMP/output/link.txt" ] || {
  printf 'not ok - symlink answer was accepted\n' >&2
  exit 1
}
pass 'symlink answer is rejected before reaching the host work directory'

tar --transform='s|^answer.txt$|../../answer.txt|' \
  -cf "$TMP/traversal.tar" -C "$TMP/source" answer.txt
set +e
python3 "$SCRIPT_DIR/extract-answer.py" \
  --name answer.txt --output "$TMP/output/traversal.txt" \
  < "$TMP/traversal.tar" >/dev/null 2>&1
traversal_rc=$?
set -e
[ "$traversal_rc" -eq 21 ] && [ ! -e "$TMP/output/traversal.txt" ] || {
  printf 'not ok - traversal archive member was accepted\n' >&2
  exit 1
}
pass 'path-traversal archive member is rejected before extraction'

truncate -s 8388609 "$TMP/source/large.txt"
tar -cf "$TMP/large.tar" -C "$TMP/source" large.txt
set +e
python3 "$SCRIPT_DIR/extract-answer.py" \
  --name large.txt --output "$TMP/output/large.txt" \
  < "$TMP/large.tar" >/dev/null 2>&1
large_rc=$?
set -e
[ "$large_rc" -eq 21 ] && [ ! -e "$TMP/output/large.txt" ] || {
  printf 'not ok - oversized answer was accepted\n' >&2
  exit 1
}
pass 'answer larger than 8 MiB is rejected from the stream header'

mkdir -p "$TMP/fake-docker-bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$DOCKER_LOG"' \
  'case "$1" in' \
  '  info) exit 0 ;;' \
  '  container)' \
  '    case "$2" in' \
  '      ls)' \
  '        case " $* " in' \
  '          *"org.cka-practice.ssh-role=target"*) printf "aaaaaaaa\n" ;;' \
  '          *"org.cka-practice.ssh-role=base"*) printf "bbbbbbbb\n" ;;' \
  '        esac' \
  '        exit 0' \
  '        ;;' \
  '      inspect)' \
  '        name="${!#}"' \
  '        case "$name" in aaaaaaaa|bbbbbbbb) ;; *) exit 1 ;; esac' \
  '        case " $* " in' \
  '          *" --format "*)' \
  '            if [ "$name" = aaaaaaaa ]; then' \
  '              printf "aaaaaaaa cleanupcontract target\n"' \
  '            else' \
  '              printf "bbbbbbbb another-run base\n"' \
  '            fi' \
  '            ;;' \
  '        esac' \
  '        exit 0' \
  '        ;;' \
  '      rm) exit 0 ;;' \
  '    esac' \
  '    ;;' \
  '  network) exit 1 ;;' \
  'esac' \
  'exit 1' > "$TMP/fake-docker-bin/docker"
chmod 0700 "$TMP/fake-docker-bin/docker"
set +e
DOCKER_LOG="$TMP/fake-docker.log" PATH="$TMP/fake-docker-bin:$PATH" \
  bash "$SCRIPT_DIR/cleanup.sh" --run-id cleanupcontract >/dev/null 2>&1
cleanup_fault_rc=$?
set -e
[ "$cleanup_fault_rc" -ne 0 ] \
  && grep -Fx 'container rm --force aaaaaaaa' "$TMP/fake-docker.log" >/dev/null || {
  printf 'not ok - secondary ownership failure prevented target cleanup\n' >&2
  exit 1
}
pass 'cleanup removes the owned target before aggregating secondary ownership failures'

mkdir -p "$TMP/deadline-state/exam"
printf 'watcher-contract\n' > "$TMP/deadline-state/exam/run-id"
printf 'watcher-ssh-run\n' > "$TMP/deadline-state/exam/ssh-run-id"
printf 'RUNNING\n' > "$TMP/deadline-state/exam/state"
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$TMP/deadline-state/exam/deadline"
printf '%s\n' '#!/usr/bin/env bash' \
  'test -s "'"$TMP"'/seal-called" || exit 9' \
  'printf "%s\\n" "$*" > "'"$TMP"'/watcher-called"' \
  'exit 0' > "$TMP/fake-runner.sh"
chmod 0700 "$TMP/fake-runner.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" > "'"$TMP"'/seal-called"' \
  'exit 0' > "$TMP/fake-seal.sh"
chmod 0700 "$TMP/fake-seal.sh"

mkdir -p "$TMP/invalid-ready-state/exam"
printf 'invalid-ready\n' > "$TMP/invalid-ready-state/exam/run-id"
printf 'invalidready\n' > "$TMP/invalid-ready-state/exam/ssh-run-id"
printf 'PREPARING\n' > "$TMP/invalid-ready-state/exam/state"
printf 'not-a-deadline\n' > "$TMP/invalid-ready-state/exam/deadline"
set +e
bash "$SCRIPT_DIR/deadline-watcher.sh" \
  --state-dir "$TMP/invalid-ready-state" \
  --run-id invalid-ready \
  --ssh-run-id invalidready \
  --seal-script "$TMP/fake-seal.sh" \
  --runner "$TMP/fake-runner.sh" \
  --ready-file "$TMP/invalid-ready-state/exam/ready" >/dev/null 2>&1
invalid_ready_rc=$?
set -e
[ "$invalid_ready_rc" -ne 0 ] \
  && [ ! -e "$TMP/invalid-ready-state/exam/ready" ] || {
  printf 'not ok - watcher published readiness before validating state\n' >&2
  exit 1
}
pass 'deadline watcher validates run identity, state, and deadline before readiness'

mkdir -p "$TMP/broken-state/exam"
printf 'broken-state\n' > "$TMP/broken-state/exam/run-id"
printf 'brokenstate\n' > "$TMP/broken-state/exam/ssh-run-id"
printf 'RUNNING\n' > "$TMP/broken-state/exam/state"
printf '%s\n' "$(( $(date +%s) + 1 ))" > "$TMP/broken-state/exam/deadline"
rm -f -- "$TMP/seal-called" "$TMP/watcher-called"
timeout 6s bash "$SCRIPT_DIR/deadline-watcher.sh" \
  --state-dir "$TMP/broken-state" \
  --run-id broken-state \
  --ssh-run-id brokenstate \
  --seal-script "$TMP/fake-seal.sh" \
  --runner "$TMP/fake-runner.sh" \
  --ready-file "$TMP/broken-state/exam/ready" &
broken_watcher_pid=$!
for _ in $(seq 1 100); do
  [ -r "$TMP/broken-state/exam/ready" ] && break
  kill -0 "$broken_watcher_pid" 2>/dev/null || break
  sleep 0.02
done
[ -r "$TMP/broken-state/exam/ready" ] || {
  printf 'not ok - broken-state watcher never became ready\n' >&2
  exit 1
}
printf 'BROKEN\n' > "$TMP/broken-state/exam/state"
set +e
wait "$broken_watcher_pid"
broken_watcher_rc=$?
set -e
[ "$broken_watcher_rc" -ne 0 ] \
  && grep -Fx -- '--run-id brokenstate' "$TMP/seal-called" >/dev/null || {
  printf 'not ok - broken state let watcher exit without sealing SSH\n' >&2
  exit 1
}
pass 'deadline watcher fail-closes an unknown state by sealing its immutable SSH run'

bash "$SCRIPT_DIR/deadline-watcher.sh" \
  --state-dir "$TMP/deadline-state" \
  --run-id watcher-contract \
  --ssh-run-id watcher-ssh-run \
  --seal-script "$TMP/fake-seal.sh" \
  --runner "$TMP/fake-runner.sh"
grep -Fx -- '--run-id watcher-ssh-run' "$TMP/seal-called" >/dev/null || {
  printf 'not ok - deadline watcher did not hard-stop the SSH run first\n' >&2
  exit 1
}
grep -Fx '__ssh-deadline watcher-contract watcher-ssh-run' "$TMP/watcher-called" >/dev/null || {
  printf 'not ok - deadline watcher did not invoke the internal seal command\n' >&2
  exit 1
}
pass 'deadline watcher hard-stops SSH before locked state sealing without a candidate action'

mkdir -p "$TMP/immutable-deadline-state/exam"
printf 'immutable-deadline\n' > "$TMP/immutable-deadline-state/exam/run-id"
printf 'immutabledeadline\n' > "$TMP/immutable-deadline-state/exam/ssh-run-id"
printf 'RUNNING\n' > "$TMP/immutable-deadline-state/exam/state"
printf '%s\n' "$(( $(date +%s) + 2 ))" > "$TMP/immutable-deadline-state/exam/deadline"
rm -f -- "$TMP/seal-called" "$TMP/watcher-called"
timeout 8s bash "$SCRIPT_DIR/deadline-watcher.sh" \
  --state-dir "$TMP/immutable-deadline-state" \
  --run-id immutable-deadline \
  --ssh-run-id immutabledeadline \
  --seal-script "$TMP/fake-seal.sh" \
  --runner "$TMP/fake-runner.sh" \
  --ready-file "$TMP/immutable-deadline-state/exam/ready" &
immutable_watcher_pid=$!
for _ in $(seq 1 100); do
  [ -r "$TMP/immutable-deadline-state/exam/ready" ] && break
  kill -0 "$immutable_watcher_pid" 2>/dev/null || break
  sleep 0.02
done
[ -r "$TMP/immutable-deadline-state/exam/ready" ] || {
  printf 'not ok - immutable deadline watcher never became ready\n' >&2
  exit 1
}
printf '%s\n' "$(( $(date +%s) + 3600 ))" \
  > "$TMP/immutable-deadline-state/exam/deadline"
wait "$immutable_watcher_pid" || {
  printf 'not ok - mutable deadline file postponed the watcher cutoff\n' >&2
  exit 1
}
grep -Fx -- '--run-id immutabledeadline' "$TMP/seal-called" >/dev/null || {
  printf 'not ok - immutable deadline watcher did not seal its SSH run\n' >&2
  exit 1
}
pass 'deadline watcher commits the validated deadline instead of rereading mutable state'

printf '1..%d\n' "$passes"
